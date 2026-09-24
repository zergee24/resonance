import Foundation
import ResonanceCore
import AppKit
import UniformTypeIdentifiers

extension AppModel {
    func recompute() {
        exportRevision = UUID()
        matchTask?.cancel()
        results = []; selectedResultID = nil
        spectrumLine = []; spectrumFrequencies = []
        matching = false
        guard (mode != .song || selectedTrack != nil), (mode != .headphone || selectedHeadphone != nil) else { return }
        let currentMode = mode
        let trackID = selectedTrackID
        let headphoneID = selectedHeadphoneID
        let candidates: [TrackEntry]
        if currentMode == .song { candidates = tracks.filter { $0.id == trackID } }
        else {
            let scope = playlists.first { $0.id == selectedPlaylistID }?.trackIDs
            candidates = tracks.filter { (scope == nil || scope!.contains($0.id)) && (!($0.analyzed) || includePartial || $0.isFull) }
        }
        let devices = headphones.filter { currentMode == .song ? $0.owned : $0.id == headphoneID }
        let allDevices = headphones.filter(\.owned)
        let curveLibrary = curves
        let sortMode = sort
        matching = true
        matchTask = Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) { () -> ([MatchPresentation], [Double], [Double]) in
                    var presentations: [MatchPresentation] = []
                    var plotX: [Double] = [], plotY: [Double] = []
                    for track in candidates {
                        try Task.checkCancellation()
                        guard let path = track.featurePath else {
                            for device in devices { presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "等待实际音频采集或导入")) }
                            continue
                        }
                        let features = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: path))
                        if currentMode == .song {
                            plotX = features.frequencyBinsHz
                            var sum = Array(repeating: 0.0, count: plotX.count)
                            for frame in features.frames { for channel in frame.powerSpectralDensityByChannel { for (i, value) in channel.enumerated() { sum[i] += value } } }
                            let count = Double(max(1, features.frames.count * features.channelCount))
                            plotY = sum.map { 10 * log10(max(1e-14, $0 / count)) }
                        }
                        for device in devices {
                            try Task.checkCancellation()
                            guard track.comparisonAllowed else {
                                presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: track.error ?? "采集处理状态未确认或存在丢帧；保留频谱，不生成通用耳机排名")); continue
                            }
                            guard let measured = curveLibrary.first(where: { $0.id == device.curveID }) else {
                                presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "缺少实测曲线")); continue
                            }
                            guard let reference = curveLibrary.first(where: { $0.id == device.referenceID && $0.isReference }) else {
                                presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "请在资料库关联兼容的参考曲线")); continue
                            }
                            guard !measured.measurementSystem.isEmpty, reference.measurementSystem == measured.measurementSystem else {
                                presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "测量体系未知或与参考不一致，不能比较")); continue
                            }
                            guard measured.validMin <= 20, measured.validMax >= 20_000, reference.validMin <= 20, reference.validMax >= 20_000, features.validMaxHz >= 20_000 else {
                                presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "20 Hz–20 kHz 覆盖不完整；不与完整范围混排")); continue
                            }
                            let curve = try Self.coreCurve(measured)
                            let target = try Self.coreCurve(reference)
                            let h = Headphone(id: device.id, name: device.name, owned: device.owned, curve: curve, referenceID: target.id)
                            let match = Matcher().match(features: features, headphone: h, reference: target)
                            var reason = "\(reference.name) · \(measured.measurementSystem)；D 越小越接近参考，C 只表示谱形变化。测量变动未量化。"
                            if let message = match.message { reason += " \(message)" }
                            var presentation = MatchPresentation(trackID: track.id, headphoneID: device.id, name: currentMode == .song ? device.name : track.title, subtitle: "\(track.coverageLabel) · \(currentMode == .song ? reference.name : track.artist)", c: match.c, d: match.d, high: match.dHigh, reason: reason, bands: match.frequencyBands.map {
                                BandPresentation(low: $0.band.lowerHz, high: $0.band.upperHz, share: $0.inputEnergyFraction, gain: $0.relativeGainDB, deviation: $0.deviationContribution, status: Self.bandStatus($0.state), actualLow: $0.actualLowerHz, actualHigh: $0.actualUpperHz)
                            }, evaluatedMin: match.evaluatedMinHz, evaluatedMax: match.evaluatedMaxHz)
                            if currentMode == .headphone && sortMode != .character {
                                let others = allDevices.filter { $0.id != device.id && $0.referenceID == reference.id }
                                var otherScores: [Double] = []
                                for other in others {
                                    guard let otherCurve = curveLibrary.first(where: { $0.id == other.curveID }), otherCurve.measurementSystem == measured.measurementSystem, otherCurve.validMin <= 20, otherCurve.validMax >= 20_000 else { continue }
                                    let otherResult = Matcher().match(features: features, headphone: Headphone(id: other.id, name: other.name, owned: true, curve: try Self.coreCurve(otherCurve), referenceID: target.id), reference: target)
                                    if let value = sortMode == .high ? otherResult.dHigh : otherResult.d { otherScores.append(value) }
                                }
                                if !otherScores.isEmpty, let value = sortMode == .high ? match.dHigh : match.d {
                                    let ordered = otherScores.sorted(), mid = ordered.count / 2
                                    let median = ordered.count % 2 == 0 ? (ordered[mid - 1] + ordered[mid]) / 2 : ordered[mid]
                                    presentation.advantage = median - value
                                }
                            }
                            presentation.comparisonGroup = "\(reference.id.uuidString):\(measured.measurementSystem)"
                            presentations.append(presentation)
                        }
                    }
                    return (Self.ordered(presentations, mode: currentMode, sort: sortMode), plotX, plotY)
                }.value
                guard !Task.isCancelled else { return }
                results = output.0; spectrumFrequencies = output.1; spectrumLine = output.2
                selectedResultID = results.first?.id
                matching = false
                status = "已评估 \(results.filter(\.eligible).count) 项 · 所有结果来自真实频响与音频"
            } catch {
                guard !Task.isCancelled else { return }
                matching = false; report(error)
            }
        }
    }

    nonisolated private static func unavailable(track: TrackEntry, device: HeadphoneEntry, mode: WorkMode, reason: String) -> MatchPresentation {
        MatchPresentation(trackID: track.id, headphoneID: device.id, name: mode == .song ? device.name : track.title, subtitle: track.coverageLabel, reason: reason, bands: [])
    }

    nonisolated private static func coreCurve(_ value: LibraryCurve) throws -> Curve {
        try Curve(id: value.id, name: value.name, points: zip(value.frequencies, value.levels).map { try CurvePoint(frequencyHz: $0.0, decibels: $0.1) }, source: value.source, measurementSystem: value.measurementSystem, validMinHz: value.validMin, validMaxHz: value.validMax, isReference: value.isReference)
    }

    nonisolated private static func bandStatus(_ value: MatchBandEvidence.EvidenceState) -> String {
        switch value { case .evaluated: return "有效"; case .noAudioContent: return "无内容"; case .partialCoverage: return "部分覆盖"; case .outsideMeasurement: return "无测量"; case .insufficientResolution: return "分辨率不足" }
    }

    nonisolated private static func ordered(_ values: [MatchPresentation], mode: WorkMode, sort: SongSort) -> [MatchPresentation] {
        let unavailable = values.filter { !$0.eligible }
        var available = values.filter(\.eligible)
        if mode == .headphone {
            if sort == .high { available = available.filter { $0.high != nil } }
            return available.enumerated().sorted { a, b in
                if sort == .character { return a.element.c == b.element.c ? a.offset < b.offset : (a.element.c ?? 0) > (b.element.c ?? 0) }
                if a.element.advantage != b.element.advantage { return (a.element.advantage ?? -.infinity) > (b.element.advantage ?? -.infinity) }
                let av = sort == .high ? a.element.high! : a.element.d!, bv = sort == .high ? b.element.high! : b.element.d!
                return av == bv ? a.offset < b.offset : av < bv
            }.map(\.element) + unavailable
        }
        var output: [MatchPresentation] = []
        for group in Set(available.map(\.comparisonGroup)).sorted() {
            var remaining = available.filter { $0.comparisonGroup == group }
            func bucket(_ value: Double) -> Double { (value / 0.5).rounded() }
            while !remaining.isEmpty {
                let front = remaining.filter { candidate in
                    !remaining.contains { other in
                        guard other.id != candidate.id else { return false }
                        let d0 = bucket(other.d!), d1 = bucket(candidate.d!)
                        if let h0 = other.high, let h1 = candidate.high { return d0 <= d1 && bucket(h0) <= bucket(h1) && (d0 < d1 || bucket(h0) < bucket(h1)) }
                        return d0 < d1
                    }
                }.sorted { a, b in a.d == b.d ? a.id < b.id : a.d! < b.d! }
                output += front
                let ids = Set(front.map(\.id)); remaining.removeAll { ids.contains($0.id) }
            }
        }
        return output + unavailable
    }

    func exportCandidatePlaylist() {
        guard let database else { return }
        let selected = results.filter(\.eligible).compactMap { result in tracks.first { $0.id == result.trackID } }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(selectedHeadphone?.name ?? "耳机")-候选歌单.json"
        panel.message = "导出可核对的候选与精确链接；这是本地结果，不代表已写入网易云。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let payload = LocalPlaylistExport(name: selectedHeadphone?.name ?? "候选歌单", createdAt: Date(), sorting: sort.rawValue, tracks: selected, source: playlists.first { $0.id == selectedPlaylistID })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: url, options: .atomic)
            try database.save(payload, kind: "exports", id: UUID().uuidString)
            status = "已导出本地候选歌单 · \(selected.count) 首；尚未写入网易云"
        } catch { report(error) }
    }
}

struct LocalPlaylistExport: Codable {
    var name: String
    var createdAt: Date
    var sorting: String
    var tracks: [TrackEntry]
    var source: PlaylistEntry?
}

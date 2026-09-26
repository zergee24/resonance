import Foundation
import ResonanceCore
import AppKit
import UniformTypeIdentifiers

extension AppModel {
    func recompute() {
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
        let curveLibrary = curves
        let personalReferences = preferredReferences
        matching = true
        matchTask = Task {
            do {
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) { () -> ([MatchPresentation], [Double], [Double]) in
                    var presentations: [MatchPresentation] = []
                    var plotX: [Double] = [], plotY: [Double] = []
                    let personalTargets = try personalReferences.map { (library: $0, curve: try Self.coreCurve($0)) }
                    for track in candidates {
                        try Task.checkCancellation()
                        guard let path = track.featurePath else {
                            for device in devices { presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "等待实际音频采集或导入")) }
                            continue
                        }
                        let features: SpectrumFeatures
                        do {
                            features = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: path))
                        } catch {
                            if error is CancellationError { throw error }
                            for device in devices {
                                presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "频谱读取失败：\(error.localizedDescription)"))
                            }
                            continue
                        }
                        if currentMode == .song {
                            plotX = features.frequencyBinsHz
                            var sum = Array(repeating: 0.0, count: plotX.count)
                            var validChannelCount = 0
                            for frame in features.frames {
                                for channel in frame.powerSpectralDensityByChannel {
                                    guard channel.count == plotX.count, channel.allSatisfy(\.isFinite) else { continue }
                                    validChannelCount += 1
                                    for index in sum.indices {
                                        sum[index] += channel[index]
                                    }
                                }
                            }
                            let count = Double(max(1, validChannelCount))
                            plotY = validChannelCount == 0 ? [] : sum.map { 10 * log10(max(1e-14, $0 / count)) }
                        }
                        for device in devices {
                            try Task.checkCancellation()
                            do {
                                guard let measured = curveLibrary.first(where: { $0.id == device.curveID }) else {
                                    presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "缺少耳机实测曲线，暂时不能计算")); continue
                                }
                                let curve = try Self.coreCurve(measured)
                                let rightCurve = try Self.rightCoreCurve(measured)
                                let h = Headphone(id: device.id, name: device.name, owned: device.owned, curve: curve, rightCurve: rightCurve, referenceID: device.referenceID)
                                let personal: PersonalMatchResult?
                                let reference: LibraryCurve
                                if personalTargets.isEmpty {
                                    personal = nil
                                    guard let selectedReferenceID = device.referenceID else {
                                        presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "请先选择参考曲线，暂时不能计算")); continue
                                    }
                                    guard let selected = curveLibrary.first(where: { $0.id == selectedReferenceID }) else {
                                        presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "找不到已选择的参考曲线，暂时不能计算")); continue
                                    }
                                    reference = selected
                                } else {
                                    let personalResult = PersonalMatcher().match(
                                        features: features,
                                        headphone: h,
                                        references: personalTargets.map(\.curve)
                                    )
                                    personal = personalResult
                                    guard let bestID = personalResult.bestReferenceID,
                                          let best = personalTargets.first(where: { $0.library.id == bestID })?.library else {
                                        var unavailable = Self.unavailable(
                                            track: track,
                                            device: device,
                                            mode: currentMode,
                                            reason: Self.personalUnavailableReason(personalResult)
                                        )
                                        unavailable.personalMatch = personalResult
                                        presentations.append(unavailable)
                                        continue
                                    }
                                    reference = best
                                }
                                let target = try Self.coreCurve(reference)
                                let match = Matcher().match(features: features, headphone: h, reference: target)
                                let reason = Self.matchReason(
                                    track: track,
                                    headphone: measured,
                                    reference: reference,
                                    match: match,
                                    personal: personal
                                )
                                var presentation = MatchPresentation(trackID: track.id, headphoneID: device.id, name: currentMode == .song ? device.name : track.title, subtitle: "\(track.coverageLabel) · \(currentMode == .song ? reference.name : track.artist)", c: match.c, d: match.d, high: match.dHigh, reason: reason, bands: match.frequencyBands.map {
                                    BandPresentation(low: $0.band.lowerHz, high: $0.band.upperHz, share: $0.inputEnergyFraction, gain: $0.relativeGainDB, deviation: $0.deviationContribution, status: Self.bandStatus($0.state), actualLow: $0.actualLowerHz, actualHigh: $0.actualUpperHz)
                                }, evaluatedMin: match.evaluatedMinHz, evaluatedMax: match.evaluatedMaxHz)
                                presentation.personalMatch = personal
                                presentation.bestReferenceID = reference.id
                                presentation.bestReferenceName = reference.name
                                presentations.append(presentation)
                            } catch {
                                if error is CancellationError { throw error }
                                presentations.append(Self.unavailable(track: track, device: device, mode: currentMode, reason: "曲线读取失败：\(error.localizedDescription)"))
                            }
                        }
                    }
                    return (presentations, plotX, plotY)
                }
                let output = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
                guard !Task.isCancelled else { return }
                results = Self.ordered(output.0, mode: mode, sort: sort)
                spectrumFrequencies = output.1; spectrumLine = output.2
                selectedResultID = results.first?.id
                matching = false
                status = "已处理 \(results.filter(\.eligible).count) 项 · 数字来自已采频谱；覆盖不足会标注为估计"
            } catch {
                guard !Task.isCancelled else { return }
                matching = false; report(error)
            }
        }
    }

    /// Reorders already computed presentations without decoding feature
    /// artifacts or rerunning either matcher. Use this for sort-only changes.
    func resortResults() {
        guard !results.isEmpty else { return }
        let selected = selectedResultID
        results = Self.ordered(results, mode: mode, sort: sort)
        selectedResultID = selected.flatMap { id in results.contains(where: { $0.id == id }) ? id : nil } ?? results.first?.id
    }

    nonisolated private static func unavailable(track: TrackEntry, device: HeadphoneEntry, mode: WorkMode, reason: String) -> MatchPresentation {
        MatchPresentation(trackID: track.id, headphoneID: device.id, name: mode == .song ? device.name : track.title, subtitle: track.coverageLabel, reason: reason, bands: [])
    }

    nonisolated private static func matchReason(
        track: TrackEntry,
        headphone: LibraryCurve,
        reference: LibraryCurve,
        match: MatchResult,
        personal: PersonalMatchResult?
    ) -> String {
        let referenceName = reference.name.isEmpty ? "已选参考曲线" : reference.name
        var parts = [highBandSummary(match), "参考：\(referenceName)。"]
        if headphone.source != reference.source || headphone.measurementSystem != reference.measurementSystem ||
            headphone.measurementSystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            reference.measurementSystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("耳机与参考来源或夹具未逐产品确认，未假定跨来源已校准；结果为估计。")
        }
        if let personal {
            if let bestID = personal.bestReferenceID,
               let best = personal.matches.first(where: { $0.referenceID == bestID }),
               let score = best.overallDeviationDB, score.isFinite {
                parts.append("个人偏好最佳参考：\(best.referenceName)，整体偏差约 \(String(format: "%.2f", score)) dB。")
            } else {
                parts.append("个人偏好参考没有可比较的最佳结果。")
            }
            if !personal.limitations.isEmpty {
                parts.append(personal.limitations.prefix(2).joined(separator: "；"))
            }
        }
        if let message = match.message, !message.isEmpty {
            parts.append(message)
        }
        if let caveat = captureCaveat(track) {
            parts.append(caveat)
        }
        return parts.joined(separator: " ")
    }

    nonisolated private static func highBandSummary(_ match: MatchResult) -> String {
        let highBands = match.frequencyBands.filter { $0.band.upperHz > 10_000 && $0.band.lowerHz < 20_000 }
        let samples = highBands.compactMap { evidence -> (gain: Double, share: Double)? in
            guard let gain = evidence.relativeGainDB, let share = evidence.inputEnergyFraction,
                  gain.isFinite, share.isFinite, share > 0 else { return nil }
            return (gain, share)
        }
        guard !samples.isEmpty else {
            if let maximum = match.evaluatedMaxHz, maximum <= 10_000 {
                return "10–20 kHz 不在实际计算频段，暂无该段概括。"
            }
            return "10–20 kHz 没有足够歌曲能量，暂不概括。"
        }
        let totalShare = samples.reduce(0) { $0 + $1.share }
        let weightedGain = samples.reduce(0) { $0 + $1.gain * $1.share } / totalShare
        guard totalShare.isFinite, totalShare > 0, weightedGain.isFinite else {
            return "10–20 kHz 没有足够歌曲能量，暂不概括。"
        }
        let direction = weightedGain > 0 ? "提升" : (weightedGain < 0 ? "衰减" : "接近不变")
        return "10–20 kHz 相对参考为\(direction)（约 \(String(format: "%+.1f", weightedGain)) dB）；歌曲该频段约占已计算能量 \(energyShareLabel(totalShare))。"
    }

    nonisolated private static func energyShareLabel(_ share: Double) -> String {
        let percent = share * 100
        if percent < 0.01 { return "<0.01%" }
        if percent < 1 { return String(format: "%.2f%%", percent) }
        return String(format: "%.0f%%", percent)
    }

    nonisolated private static func captureCaveat(_ track: TrackEntry) -> String? {
        var notes: [String] = []
        if let analysisNotes = track.analysisNotes {
            notes.append(contentsOf: analysisNotes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(2))
        }
        if let droppedFrames = track.droppedFrames, droppedFrames > 0 {
            notes.append("采集有 \(droppedFrames) 个丢帧")
        }
        if let error = track.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty,
           error != "音频已保存，等待分析" {
            notes.append(error.replacingOccurrences(of: "不参与自动排名", with: "未完全核实"))
        }
        guard !notes.isEmpty else { return nil }
        var unique: [String] = []
        for note in notes where !unique.contains(note) {
            unique.append(note)
        }
        return unique.joined(separator: "；") + "。"
    }

    nonisolated private static func prepareComparisonMetadata(
        _ values: [MatchPresentation],
        mode: WorkMode,
        sort: SongSort
    ) -> [MatchPresentation] {
        values.map { value in
            var prepared = value
            guard value.eligible else { return prepared }

            let usePersonalGroup = value.personalMatch != nil && (mode == .song || sort == .personal)
            if usePersonalGroup, let personal = value.personalMatch {
                let references = personal.matches.map { $0.referenceID.uuidString }.sorted().joined(separator: ",")
                let minimum = personal.commonMinimumHz ?? value.evaluatedMin
                let maximum = personal.commonMaximumHz.map { min($0, 20_000) } ?? value.evaluatedMax.map { min($0, 20_000) }
                let range = "\(Self.formatRange(minimum))–\(Self.formatRange(maximum)) Hz"
                prepared.comparisonGroup = "personal:\(personal.modelVersion):\(references):\(Self.formatRange(minimum))-\(Self.formatRange(maximum))"
                prepared.comparisonLabel = "个人参考组 · \(range) · 听觉频带偏差"
            } else {
                let reference = value.bestReferenceID?.uuidString ?? "未知参考"
                let minimum = value.evaluatedMin
                let maximum = value.evaluatedMax
                prepared.comparisonGroup = "legacy:\(reference):\(Self.formatRange(minimum))-\(Self.formatRange(maximum))"
                let name = value.bestReferenceName ?? "已选参考曲线"
                prepared.comparisonLabel = "\(name) · \(Self.formatRange(minimum))–\(Self.formatRange(maximum)) Hz"
            }
            return prepared
        }
    }

    nonisolated private static func formatRange(_ value: Double?) -> String {
        value.map { String(format: "%.6g", $0) } ?? "未知"
    }

    nonisolated private static func coreCurve(_ value: LibraryCurve) throws -> Curve {
        try Curve(id: value.id, name: value.name, points: zip(value.frequencies, value.levels).map { try CurvePoint(frequencyHz: $0.0, decibels: $0.1) }, source: value.source, measurementSystem: value.measurementSystem, validMinHz: value.validMin, validMaxHz: value.validMax, isReference: value.isReference)
    }

    nonisolated private static func rightCoreCurve(_ value: LibraryCurve) throws -> Curve? {
        guard let rightLevels = value.rightLevels,
              rightLevels.count == value.frequencies.count else { return nil }
        return try Curve(id: value.id, name: "\(value.name) · R", points: zip(value.frequencies, rightLevels).map { try CurvePoint(frequencyHz: $0.0, decibels: $0.1) }, source: value.source, measurementSystem: value.measurementSystem, validMinHz: value.validMin, validMaxHz: value.validMax, isReference: false, channel: .right)
    }

    nonisolated private static func personalUnavailableReason(_ result: PersonalMatchResult) -> String {
        var parts = ["个人参考没有产生可排序的整体偏差。"]
        parts.append(contentsOf: result.limitations.prefix(2))
        if parts.count == 1 { parts.append("共同支持频段或歌曲能量不足。") }
        return parts.joined(separator: "；")
    }

    nonisolated private static func bandStatus(_ value: MatchBandEvidence.EvidenceState) -> String {
        switch value { case .evaluated: return "有效"; case .noAudioContent: return "无内容"; case .partialCoverage: return "部分覆盖"; case .outsideMeasurement: return "无测量"; case .insufficientResolution: return "分辨率不足" }
    }

    nonisolated private static func ordered(_ values: [MatchPresentation], mode: WorkMode, sort: SongSort) -> [MatchPresentation] {
        let prepared = prepareComparisonMetadata(values, mode: mode, sort: sort)
        let unavailable = prepared.filter { !$0.eligible }
        let available = prepared.filter(\.eligible)
        var output: [MatchPresentation] = []
        let groups = Dictionary(grouping: available, by: \.comparisonGroup)
        for groupID in groups.keys.sorted() {
            let group = groups[groupID] ?? []
            let sorted = group.enumerated().sorted { left, right in
                let leftValue: Double?
                let rightValue: Double?
                let ascending: Bool
                if mode == .song {
                    if left.element.personalScore != nil || right.element.personalScore != nil {
                        leftValue = left.element.personalScore
                        rightValue = right.element.personalScore
                    } else {
                        leftValue = left.element.d
                        rightValue = right.element.d
                    }
                    ascending = true
                } else {
                    switch sort {
                    case .character:
                        leftValue = left.element.c
                        rightValue = right.element.c
                        ascending = false
                    case .personal:
                        leftValue = left.element.personalScore ?? left.element.d
                        rightValue = right.element.personalScore ?? right.element.d
                        ascending = true
                    case .balanced:
                        leftValue = left.element.d
                        rightValue = right.element.d
                        ascending = true
                    case .high:
                        leftValue = left.element.high
                        rightValue = right.element.high
                        ascending = true
                    }
                }
                switch (leftValue, rightValue) {
                case let (left?, right?):
                    if left != right { return ascending ? left < right : left > right }
                case (nil, nil):
                    break
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                }
                return left.element.id == right.element.id ? left.offset < right.offset : left.element.id < right.element.id
            }.map(\.element)
            output.append(contentsOf: sorted)
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

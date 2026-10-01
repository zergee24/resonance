import Foundation

/// Matches a recorded spectrum to a measured headphone curve and an explicit
/// reference. The result is deliberately descriptive: C measures observable
/// spectral change, while D and D_high measure curve deviation after removing
/// one global level offset. None of the metrics is a subjective sound-quality
/// score.
public struct Matcher: Sendable {
    public struct Configuration: Codable, Sendable, Equatable {
        public let minimumFrequencyHz: Double
        public let maximumFrequencyHz: Double
        public let highFrequencyMinimumHz: Double
        public let highFrequencyMaximumHz: Double
        public let minimumHighEnergyRatio: Double
        public let modelVersion: String

        public init(
            minimumFrequencyHz: Double = 20,
            maximumFrequencyHz: Double = 20_000,
            highFrequencyMinimumHz: Double = 10_000,
            highFrequencyMaximumHz: Double = 20_000,
            minimumHighEnergyRatio: Double = 1e-4,
            modelVersion: String = "3-cd-c-high-channel-linear"
        ) {
            self.minimumFrequencyHz = minimumFrequencyHz
            self.maximumFrequencyHz = maximumFrequencyHz
            self.highFrequencyMinimumHz = highFrequencyMinimumHz
            self.highFrequencyMaximumHz = highFrequencyMaximumHz
            self.minimumHighEnergyRatio = minimumHighEnergyRatio
            self.modelVersion = modelVersion
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func match(
        features: SpectrumFeatures,
        headphone: Headphone,
        reference: Curve?
    ) -> MatchResult {
        guard let headphoneCurve = headphone.curve else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .missingHeadphoneCurve,
                message: "缺少耳机实测曲线，暂时不能计算。"
            )
        }
        guard let reference else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: nil,
                reason: .missingReference,
                message: "请先选择参考曲线，暂时不能计算。"
            )
        }
        guard !features.frames.isEmpty else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noSpectrumFrames,
                message: "没有可用的频谱帧，暂时不能计算。"
            )
        }
        guard features.frequencyBinsHz.count >= 2,
              features.frequencyBinsHz.allSatisfy(\.isFinite),
              zip(features.frequencyBinsHz, features.frequencyBinsHz.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              validCellEdges(features),
              features.frames.allSatisfy({ frame in
                  frame.powerSpectralDensityByChannel.count == features.channelCount
                      && frame.powerSpectralDensityByChannel.allSatisfy {
                          $0.count == features.frequencyBinsHz.count
                              && $0.allSatisfy(\.isFinite)
                      }
              }) else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .invalidInput,
                message: "频率轴、显式 cell 边界或各声道 PSD 形状不一致，暂时不能计算。"
            )
        }

        return compute(
            features: features,
            headphone: headphone,
            headphoneCurve: headphoneCurve,
            reference: reference
        )
    }

    /// Convenience overload for adapters that keep a curve independently of
    /// the persistence model. The explicit reference is the algorithm input;
    /// the persistence model's optional reference ID is not a second gate.
    public func match(
        features: SpectrumFeatures,
        headphoneID: UUID,
        curve: Curve?,
        reference: Curve?,
        referenceID: UUID?
    ) -> MatchResult {
        let headphone = Headphone(
            id: headphoneID,
            name: curve?.name ?? "Unknown headphone",
            owned: true,
            curve: curve,
            referenceID: referenceID
        )
        return match(features: features, headphone: headphone, reference: reference)
    }

    private func compute(
        features: SpectrumFeatures,
        headphone: Headphone,
        headphoneCurve: Curve,
        reference: Curve
    ) -> MatchResult {
        // A stereo measurement has one transfer curve per measured channel.
        // Intersect only the curves that can contribute to the recorded
        // channels; a right-channel curve must not constrain a mono recording.
        let channelCurves = curvesForChannels(
            leftCurve: headphoneCurve,
            rightCurve: headphone.rightCurve,
            channelCount: features.channelCount
        )
        let supportCurves = channelCurves + (headphone.eqCurve.map { [$0] } ?? [])
        let curveMinimum = max(supportCurves.map(\.validMinHz).max() ?? headphoneCurve.validMinHz, reference.validMinHz)
        let curveMaximum = min(supportCurves.map(\.validMaxHz).min() ?? headphoneCurve.validMaxHz, reference.validMaxHz)
        let minimum = max(configuration.minimumFrequencyHz, features.validMinHz, curveMinimum)
        let maximum = min(configuration.maximumFrequencyHz, features.validMaxHz, curveMaximum)
        guard minimum.isFinite, maximum.isFinite, minimum < maximum else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noCommonFrequencyCoverage,
                message: "音频、耳机曲线与参考曲线没有共同频段，暂时不能计算。"
            )
        }

        // C/D/D_high use the fixed 20–20 kHz comparison range. Evidence bands
        // are independent: when all inputs contain validated bins above 20 kHz
        // they continue into the nominal 20–25, 25–31.5 ... display bands.
        let detailMinimum = max(configuration.minimumFrequencyHz, features.validMinHz, curveMinimum)
        let detailMaximum = min(features.validMaxHz, curveMaximum)
        guard detailMinimum.isFinite, detailMaximum.isFinite, detailMinimum < detailMaximum else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noCommonFrequencyCoverage,
                message: "音频与两条曲线没有共同的明细频段，暂时不能计算。"
            )
        }

        let bins = features.frequencyBinsHz.enumerated().compactMap { index, frequency -> Int? in
            guard frequency.isFinite, frequency >= minimum, frequency <= maximum else { return nil }
            return index
        }
        guard bins.count >= 2 else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .insufficientResolution,
                message: "共同频段的频谱分辨率不足，暂时不能计算。"
            )
        }

        let detailBins = features.frequencyBinsHz.enumerated().compactMap { index, frequency -> Int? in
            guard frequency.isFinite, frequency >= detailMinimum, frequency <= detailMaximum else { return nil }
            return index
        }
        guard detailBins.count >= 2 else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .insufficientResolution,
                message: "共同明细频段的频谱分辨率不足，暂时不能计算。"
            )
        }

        guard let channelDeltas = deltaValuesByChannel(
            bins: bins,
            frequencies: features.frequencyBinsHz,
            channelCurves: channelCurves,
            headphone: headphone,
            reference: reference
        ) else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noCommonFrequencyCoverage,
                message: "共同频段内无法从曲线取得完整数值，暂时不能计算。"
            )
        }
        guard let detailChannelDeltas = deltaValuesByChannel(
            bins: detailBins,
            frequencies: features.frequencyBinsHz,
            channelCurves: channelCurves,
            headphone: headphone,
            reference: reference
        ) else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noCommonFrequencyCoverage,
                message: "共同明细频段内无法从曲线取得完整数值，暂时不能计算。"
            )
        }

        let widths = binWidths(
            frequencies: features.frequencyBinsHz,
            indices: bins,
            lowerBound: minimum,
            upperBound: maximum,
            cellEdges: validatedCellEdges(features)
        )
        let detailWidths = binWidths(
            frequencies: features.frequencyBinsHz,
            indices: detailBins,
            lowerBound: detailMinimum,
            upperBound: detailMaximum,
            cellEdges: validatedCellEdges(features)
        )
        let detailTotalEnergy = totalEnergy(
            features: features,
            bins: detailBins,
            widths: detailWidths
        )
        var totalEnergy = 0.0
        let gainAnchor = channelDeltas.first?.first ?? 0
        var weightedRelativeDelta = 0.0
        // Keep one small aggregate per channel/bin. Computing variance from
        // raw second moments (sum(E * delta^2) - gain^2 * sum(E)) loses all
        // precision when the whole curve has a large constant offset.
        var energyByChannelAndBin = channelDeltas.map { _ in
            Array(repeating: 0.0, count: bins.count)
        }
        var frameContributions: [(weight: Double, value: Double)] = []

        for frame in features.frames {
            let channelPowerArrays = channelPowers(
                frame: frame,
                channelCount: features.channelCount,
                indices: bins
            )
            guard channelPowerArrays.count == channelDeltas.count,
                  channelPowerArrays.allSatisfy({ $0.count == bins.count }) else { continue }
            let channelEnergies = channelPowerArrays.map { powers in
                zip(powers, widths).map { max(0, $0.0) * $0.1 }
            }
            let frameEnergy = channelEnergies.reduce(0) { partial, energies in
                partial + energies.reduce(0, +)
            }
            guard frameEnergy.isFinite, frameEnergy > 0 else { continue }
            totalEnergy += frameEnergy
            for (channelIndex, energies) in channelEnergies.enumerated() {
                let deltas = channelDeltas[channelIndex]
                for (localIndex, energy) in energies.enumerated() {
                    energyByChannelAndBin[channelIndex][localIndex] += energy
                    weightedRelativeDelta += energy * (deltas[localIndex] - gainAnchor)
                }
            }

            // C keeps stereo channels as separate dimensions. The offset is
            // chosen from the active channels in this frame, so a silent
            // right channel cannot affect a left-only recording through its
            // unrelated response curve.
            let activeDeltaOffset = channelDeltas
                .enumerated()
                .filter { channelIndex, _ in
                    channelEnergies[channelIndex].reduce(0, +) > 0
                }
                .flatMap { $0.element }
                .max() ?? 0
            let cFrameEnergy = frameEnergy
            // JS only depends on relative gains. Subtracting one common
            // maximum keeps the exponent bounded without changing the
            // normalized distribution, and makes C invariant to a global
            // curve/reference level offset.
            let q = channelEnergies.enumerated().flatMap { channelIndex, energies in
                zip(energies, channelDeltas[channelIndex]).map { energy, delta in
                    energy * safeGain(forDecibels: delta - activeDeltaOffset)
                }
            }
            let flattenedChannelEnergies = channelEnergies.flatMap { $0 }
            let qTotal = q.reduce(0, +)
            if cFrameEnergy.isFinite, cFrameEnergy > 0, qTotal.isFinite, qTotal > 0 {
                let pDistribution = flattenedChannelEnergies.map { $0 / cFrameEnergy }
                let qDistribution = q.map { $0 / qTotal }
                let js = jsDivergence(p: pDistribution, q: qDistribution)
                if js.isFinite {
                    frameContributions.append((cFrameEnergy, js))
                }
            }
        }

        guard totalEnergy.isFinite, totalEnergy > 0 else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noSpectrumFrames,
                message: "共同频段没有有限且非零的音频能量，暂时不能计算。"
            )
        }

        let relativeGlobalGain = weightedRelativeDelta / totalEnergy
        let variance = energyByChannelAndBin.enumerated().reduce(0.0) { partial, channel in
            let deltas = channelDeltas[channel.offset]
            return partial + zip(channel.element, deltas).reduce(0.0) {
                $0 + $1.0 * pow(($1.1 - gainAnchor) - relativeGlobalGain, 2)
            }
        }
        let d = sqrt(max(0, variance / totalEnergy))
        let c: Double?
        let cWeight = frameContributions.reduce(0) { $0 + $1.weight }
        if cWeight > 0 {
            c = frameContributions.reduce(0) { $0 + $1.weight * $1.value } / cWeight
        } else {
            c = nil
        }

        let highLocalIndices = bins.indices.filter { localIndex in
            let index = bins[localIndex]
            let frequency = features.frequencyBinsHz[index]
            return frequency >= configuration.highFrequencyMinimumHz
                && frequency <= configuration.highFrequencyMaximumHz
        }
        let highBinIndices = highLocalIndices.map { bins[$0] }
        let highActualMinimumHz = highBinIndices.first.map { features.frequencyBinsHz[$0] }
        let highActualMaximumHz = highBinIndices.last.map { features.frequencyBinsHz[$0] }
        let highEnergy = energyByChannelAndBin.reduce(0.0) { partial, channelEnergies in
            partial + highLocalIndices.reduce(0.0) { $0 + channelEnergies[$1] }
        }
        let highRatio = highEnergy / totalEnergy
        let dHigh: Double?
        if !highBinIndices.isEmpty, highEnergy.isFinite, highEnergy > 0 {
            let highWeightedVariance = energyByChannelAndBin.enumerated().reduce(0.0) { partial, channel in
                let deltas = channelDeltas[channel.offset]
                return partial + highLocalIndices.reduce(0.0) {
                    $0 + channel.element[$1] * pow((deltas[$1] - gainAnchor) - relativeGlobalGain, 2)
                }
            }
            dHigh = sqrt(max(0, highWeightedVariance / highEnergy))
        } else {
            dHigh = nil
        }

        let evidence = makeEvidence(
            features: features,
            bands: FrequencyBand.expanded(through: detailMaximum),
            bins: detailBins,
            frequencies: features.frequencyBinsHz,
            cellEdges: validatedCellEdges(features),
            channelDeltas: detailChannelDeltas,
            totalEnergy: detailTotalEnergy,
            gainAnchor: gainAnchor,
            relativeGlobalGain: relativeGlobalGain,
            commonMinimum: detailMinimum,
            commonMaximum: detailMaximum
        )

        let evaluationStatus: MatchEvaluationStatus = features.coverage.kind == .complete && !features.coverage.hasUnexplainedGaps
            ? .evaluated
            : .partial
        let coverageMessage = evaluationMessage(
            features: features,
            minimumHz: minimum,
            maximumHz: maximum,
            highMinimumHz: highActualMinimumHz,
            highMaximumHz: highActualMaximumHz,
            highEnergyRatio: highRatio,
            hasHighMetric: dHigh != nil
        )

        return MatchResult(
            recordingID: features.recordingID,
            headphoneID: headphone.id,
            referenceID: reference.id,
            status: evaluationStatus,
            message: coverageMessage,
            c: c,
            d: d,
            dHigh: dHigh,
            highFrequencyEnergyRatio: highRatio,
            evaluatedMinHz: minimum,
            evaluatedMaxHz: maximum,
            frequencyValidity: features.frequencyValidity,
            completeOrPartial: features.coverage.kind,
            frequencyBands: evidence,
            modelVersion: resultModelVersion(for: features)
        )
    }

    private func evaluationMessage(
        features: SpectrumFeatures,
        minimumHz: Double,
        maximumHz: Double,
        highMinimumHz: Double?,
        highMaximumHz: Double?,
        highEnergyRatio: Double,
        hasHighMetric: Bool
    ) -> String {
        let recordedSeconds = features.coverage.recordedDurationSeconds ?? features.durationSeconds
        let secondsText: String
        if recordedSeconds.isFinite, recordedSeconds >= 0 {
            secondsText = String(format: "%.1f", recordedSeconds)
        } else {
            secondsText = "未知"
        }

        var parts = [
            "按已采 \(secondsText) 秒内容估计",
            "实际计算 \(formatFrequency(minimumHz))–\(formatFrequency(maximumHz)) Hz"
        ]
        if features.coverage.hasUnexplainedGaps {
            parts.append("发现未解释缺口，缺口未按静音补入")
        }
        switch features.coverage.kind {
        case .complete:
            break
        case .partial:
            parts.append("覆盖不完整")
        case .unknown:
            parts.append("覆盖范围未知")
        case .unavailable:
            parts.append("覆盖信息不可用")
        }
        if let highMinimumHz, let highMaximumHz {
            var highPart = "高频实际计算 \(formatFrequency(highMinimumHz))–\(formatFrequency(highMaximumHz)) Hz"
            if !hasHighMetric {
                highPart += "；没有有限且非零的高频能量，D_high 暂无数值"
            } else if highEnergyRatio < configuration.minimumHighEnergyRatio {
                highPart += "；该段能量较少，D_high 仅基于实际高频内容"
            }
            parts.append(highPart)
        }
        if !features.coverage.identityConfirmed {
            parts.append("歌曲身份或播放位置尚未完全核实")
        }
        if features.compactStorage != nil {
            parts.append(Self.compactApproximationLimitation)
            if features.frequencyValidity == .mathematicalNyquist {
                parts.append("频率上限仍只是 PCM 的数学 Nyquist，不证明对应频段含有实测内容")
            }
        }
        return parts.joined(separator: "；") + "。"
    }

    private func formatFrequency(_ frequencyHz: Double) -> String {
        guard frequencyHz.isFinite else { return "未知" }
        if frequencyHz >= 1_000 {
            return String(format: "%.4gk", frequencyHz / 1_000)
        }
        return String(format: "%.4g", frequencyHz)
    }

    private func unevaluable(
        features: SpectrumFeatures,
        headphone: Headphone,
        reference: Curve?,
        reason: MatchUnevaluableReason,
        message: String
    ) -> MatchResult {
        MatchResult(
            recordingID: features.recordingID,
            headphoneID: headphone.id,
            referenceID: reference?.id ?? headphone.referenceID,
            status: .unevaluable,
            unevaluableReason: reason,
            message: message,
            frequencyValidity: features.frequencyValidity,
            completeOrPartial: features.coverage.kind,
            modelVersion: resultModelVersion(for: features)
        )
    }

    private static let compactApproximationLimitation =
        "compact 频谱按 cell 内 PSD 密度积分后以中心频率近似曲线权重；高 Q 峰、峰位与 20 kHz 边界可能改变，不能视为无损或与原始逐频率结果数学等价"

    private func resultModelVersion(for features: SpectrumFeatures) -> String {
        features.compactStorage == nil
            ? configuration.modelVersion
            : configuration.modelVersion + "-compact-v1"
    }

    private func channelPowers(frame: SpectrumFrame, channelCount: Int, indices: [Int]) -> [[Double]] {
        let channels = min(channelCount, frame.powerSpectralDensityByChannel.count)
        guard channels > 0 else { return [] }
        return (0..<channels).map { channelIndex in
            indices.map { index in
                guard index < frame.powerSpectralDensityByChannel[channelIndex].count else { return 0 }
                let value = frame.powerSpectralDensityByChannel[channelIndex][index]
                return value.isFinite && value >= 0 ? value : 0
            }
        }
    }

    private func validCellEdges(_ features: SpectrumFeatures) -> Bool {
        if features.compactStorage != nil, features.frequencyCellEdgesHz == nil { return false }
        guard features.frequencyCellEdgesHz != nil else { return true }
        return validatedCellEdges(features) != nil
    }

    private func validatedCellEdges(_ features: SpectrumFeatures) -> [Double]? {
        guard let edges = features.frequencyCellEdgesHz else { return nil }
        let frequencies = features.frequencyBinsHz
        guard edges.count == frequencies.count + 1,
              edges.allSatisfy(\.isFinite),
              zip(edges, edges.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              frequencies.indices.allSatisfy({ index in
                  edges[index] <= frequencies[index] && frequencies[index] <= edges[index + 1]
              }) else {
            return nil
        }
        return edges
    }

    private func curvesForChannels(leftCurve: Curve, rightCurve: Curve?, channelCount: Int) -> [Curve] {
        guard channelCount > 0 else { return [] }
        return (0..<channelCount).map { channelIndex in
            channelIndex == 1 ? (rightCurve ?? leftCurve) : leftCurve
        }
    }

    private func deltaValuesByChannel(
        bins: [Int],
        frequencies: [Double],
        channelCurves: [Curve],
        headphone: Headphone,
        reference: Curve
    ) -> [[Double]]? {
        var result: [[Double]] = []
        result.reserveCapacity(channelCurves.count)
        for curve in channelCurves {
            var values: [Double] = []
            values.reserveCapacity(bins.count)
            for index in bins {
                let frequency = frequencies[index]
                guard let headphoneDB = curve.value(at: frequency),
                      let referenceDB = reference.value(at: frequency) else {
                    return nil
                }
                var delta = headphoneDB - referenceDB
                if let eqCurve = headphone.eqCurve {
                    guard let eqValue = eqCurve.value(at: frequency) else { return nil }
                    delta += eqValue
                }
                guard delta.isFinite else { return nil }
                values.append(delta)
            }
            result.append(values)
        }
        return result
    }

    private func totalEnergy(features: SpectrumFeatures, bins: [Int], widths: [Double]) -> Double {
        var result = 0.0
        for frame in features.frames {
            let channelArrays = channelPowers(frame: frame, channelCount: features.channelCount, indices: bins)
            for powers in channelArrays {
                result += zip(powers, widths).reduce(0) { partial, pair in
                    let value = pair.0.isFinite && pair.0 >= 0 ? pair.0 : 0
                    return partial + value * pair.1
                }
            }
        }
        return result.isFinite ? result : 0
    }

    private func binWidths(
        frequencies: [Double],
        indices: [Int],
        lowerBound: Double,
        upperBound: Double,
        cellEdges: [Double]?
    ) -> [Double] {
        indices.map { index in
            let cellLower: Double
            let cellUpper: Double
            if let cellEdges {
                cellLower = cellEdges[index]
                cellUpper = cellEdges[index + 1]
            } else {
                if index == 0 {
                    cellLower = frequencies[index]
                } else {
                    cellLower = (frequencies[index - 1] + frequencies[index]) / 2
                }
                if index == frequencies.count - 1 {
                    cellUpper = frequencies[index]
                } else {
                    cellUpper = (frequencies[index] + frequencies[index + 1]) / 2
                }
            }
            let lower = max(cellLower, lowerBound)
            let upper = min(cellUpper, upperBound)
            let width = upper - lower
            return width.isFinite && width > 0 ? width : 1
        }
    }

    private func cellWidth(frequencies: [Double], index: Int, cellEdges: [Double]?) -> Double {
        if let cellEdges {
            let width = cellEdges[index + 1] - cellEdges[index]
            return width.isFinite && width > 0 ? width : 0
        }
        let lower = index == 0
            ? frequencies[index]
            : (frequencies[index - 1] + frequencies[index]) / 2
        let upper = index == frequencies.count - 1
            ? frequencies[index]
            : (frequencies[index] + frequencies[index + 1]) / 2
        let width = upper - lower
        return width.isFinite && width > 0 ? width : 0
    }

    private func cellOverlapWidth(
        frequencies: [Double],
        index: Int,
        lower: Double,
        upper: Double,
        cellEdges: [Double]?
    ) -> Double {
        let cellLower: Double
        let cellUpper: Double
        if let cellEdges {
            cellLower = cellEdges[index]
            cellUpper = cellEdges[index + 1]
        } else {
            if index == 0 {
                cellLower = frequencies[index]
            } else {
                cellLower = (frequencies[index - 1] + frequencies[index]) / 2
            }
            if index == frequencies.count - 1 {
                cellUpper = frequencies[index]
            } else {
                cellUpper = (frequencies[index] + frequencies[index + 1]) / 2
            }
        }
        let overlap = min(cellUpper, upper) - max(cellLower, lower)
        return overlap.isFinite && overlap > 0 ? overlap : 0
    }

    private func safeGain(forDecibels decibels: Double) -> Double {
        let bounded = min(120, max(-120, decibels))
        let gain = pow(10, bounded / 10)
        return gain.isFinite && gain > 0 ? gain : 1
    }

    private func jsDivergence(p: [Double], q: [Double]) -> Double {
        guard p.count == q.count else { return .nan }
        var result = 0.0
        for (pValue, qValue) in zip(p, q) {
            let midpoint = (pValue + qValue) / 2
            if pValue > 0, midpoint > 0 {
                result += 0.5 * pValue * log2(pValue / midpoint)
            }
            if qValue > 0, midpoint > 0 {
                result += 0.5 * qValue * log2(qValue / midpoint)
            }
        }
        return max(0, result)
    }

    private func makeEvidence(
        features: SpectrumFeatures,
        bands: [FrequencyBand],
        bins: [Int],
        frequencies: [Double],
        cellEdges: [Double]?,
        channelDeltas: [[Double]],
        totalEnergy: Double,
        gainAnchor: Double,
        relativeGlobalGain: Double,
        commonMinimum: Double,
        commonMaximum: Double
    ) -> [MatchBandEvidence] {
        // Precomputed overlaps keep the same cell-integration semantics while
        // visiting only bins that belong to a band. Read the already-decoded
        // PSD arrays directly below; do not create a second frames × bins
        // cache just for evidence.
        return bands.map { band in
            let lower = max(band.lowerHz, commonMinimum)
            let upper = min(band.upperHz, commonMaximum)
            guard lower < upper else {
                return MatchBandEvidence(
                    band: band,
                    actualLowerHz: nil,
                    actualUpperHz: nil,
                    inputEnergyFraction: nil,
                    relativeGainDB: nil,
                    deviationContribution: nil,
                    peakTimeSeconds: nil,
                    state: .outsideMeasurement
                )
            }

            let overlappingBins = bins.enumerated().compactMap { localIndex, index -> (localIndex: Int, index: Int, overlap: Double)? in
                let overlap = cellOverlapWidth(
                    frequencies: frequencies,
                    index: index,
                    lower: lower,
                    upper: upper,
                    cellEdges: cellEdges
                )
                return overlap > 0 ? (localIndex, index, overlap) : nil
            }

            var bandEnergy = 0.0
            var weightedDelta = 0.0
            var weightedVariance = 0.0
            var peakEnergy = 0.0
            var peakTime: Double?
            for frame in features.frames {
                var frameBandEnergy = 0.0
                let channelCount = min(features.channelCount, frame.powerSpectralDensityByChannel.count)
                for channelIndex in 0..<channelCount {
                    let powers = frame.powerSpectralDensityByChannel[channelIndex]
                    guard channelIndex < channelDeltas.count else { continue }
                    let deltas = channelDeltas[channelIndex]
                    for (localIndex, index, overlap) in overlappingBins {
                        guard index < powers.count else { continue }
                        let value = powers[index]
                        let energy = (value.isFinite && value >= 0 ? value : 0) * overlap
                        frameBandEnergy += energy
                        bandEnergy += energy
                        weightedDelta += energy * (deltas[localIndex] - gainAnchor)
                    }
                }
                if frameBandEnergy > peakEnergy {
                    peakEnergy = frameBandEnergy
                    peakTime = frame.startTimeSeconds
                }
            }

            guard bandEnergy > 0, bandEnergy.isFinite else {
                return MatchBandEvidence(
                    band: band,
                    actualLowerHz: lower,
                    actualUpperHz: upper,
                    inputEnergyFraction: 0,
                    relativeGainDB: nil,
                    deviationContribution: nil,
                    peakTimeSeconds: nil,
                    state: .noAudioContent
                )
            }
            let meanDelta = weightedDelta / bandEnergy - relativeGlobalGain
            for frame in features.frames {
                let channelCount = min(features.channelCount, frame.powerSpectralDensityByChannel.count)
                for channelIndex in 0..<channelCount {
                    let powers = frame.powerSpectralDensityByChannel[channelIndex]
                    guard channelIndex < channelDeltas.count else { continue }
                    let deltas = channelDeltas[channelIndex]
                    for (localIndex, index, overlap) in overlappingBins {
                        guard index < powers.count else { continue }
                        let value = powers[index]
                        let energy = (value.isFinite && value >= 0 ? value : 0) * overlap
                        weightedVariance += energy * pow((deltas[localIndex] - gainAnchor) - relativeGlobalGain, 2)
                    }
                }
            }
            let isPartial = lower > band.lowerHz || upper < band.upperHz
            // Preserve the native nil-edges diagnostic exactly. Compact input
            // carries its real cell widths, which replace the uniform FFT
            // spacing estimate here.
            let resolutionWidth: Double
            if cellEdges == nil {
                resolutionWidth = features.sampleRate / Double(features.parameters.frameLength)
            } else {
                resolutionWidth = overlappingBins
                    .map { cellWidth(frequencies: frequencies, index: $0.index, cellEdges: cellEdges) }
                    .max() ?? 0
            }
            let isResolutionLimited = resolutionWidth.isFinite
                && resolutionWidth > 0
                && (upper - lower) < resolutionWidth
            return MatchBandEvidence(
                band: band,
                actualLowerHz: lower,
                actualUpperHz: upper,
                inputEnergyFraction: bandEnergy / totalEnergy,
                relativeGainDB: meanDelta,
                deviationContribution: sqrt(max(0, weightedVariance / totalEnergy)),
                peakTimeSeconds: peakTime,
                state: isResolutionLimited ? .insufficientResolution : (isPartial ? .partialCoverage : .evaluated)
            )
        }
    }
}

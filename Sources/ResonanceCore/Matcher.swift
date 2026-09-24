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
            modelVersion: String = "1-cd-c-high"
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
                message: "No headphone measurement curve is available."
            )
        }
        guard let reference else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: nil,
                reason: .missingReference,
                message: "An applicable reference response is required."
            )
        }
        guard let referenceID = headphone.referenceID, referenceID == reference.id, reference.isReference else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .missingReference,
                message: "The supplied reference does not match the headphone configuration."
            )
        }
        guard features.coverage.isUsable else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .missingCoverage,
                message: "The recording has no usable complete or partial coverage."
            )
        }
        guard !features.frames.isEmpty else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noSpectrumFrames,
                message: "No spectrum frames are available."
            )
        }
        guard features.frequencyBinsHz.count >= 2,
              features.frequencyBinsHz.allSatisfy(\.isFinite),
              zip(features.frequencyBinsHz, features.frequencyBinsHz.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              features.frames.allSatisfy({ frame in
                  frame.powerSpectralDensityByChannel.count == features.channelCount
                      && frame.powerSpectralDensityByChannel.allSatisfy { $0.count == features.frequencyBinsHz.count }
              }) else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .invalidInput,
                message: "The spectrum frequency axis and per-channel PSD shapes are inconsistent."
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
    /// the persistence model. The reference and IDs remain explicit so an
    /// accidental reference mismatch cannot produce a score.
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
        let curveMinimum = max(headphoneCurve.validMinHz, reference.validMinHz)
        let curveMaximum = min(headphoneCurve.validMaxHz, reference.validMaxHz)
        let minimum = max(configuration.minimumFrequencyHz, features.validMinHz, curveMinimum)
        let maximum = min(configuration.maximumFrequencyHz, features.validMaxHz, curveMaximum)
        guard minimum.isFinite, maximum.isFinite, minimum < maximum else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noCommonFrequencyCoverage,
                message: "The audio, headphone, and reference curves have no common frequency coverage."
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
                message: "The audio, headphone, and reference curves have no common detail coverage."
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
                message: "The spectrum has fewer than two bins in the common frequency range."
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
                message: "The spectrum has fewer than two bins in the common detail range."
            )
        }

        guard let deltas = deltaValues(
            bins: bins,
            frequencies: features.frequencyBinsHz,
            headphone: headphone,
            headphoneCurve: headphoneCurve,
            reference: reference
        ) else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noCommonFrequencyCoverage,
                message: "A curve value could not be interpolated across the common frequency range."
            )
        }
        guard let detailDeltas = deltaValues(
            bins: detailBins,
            frequencies: features.frequencyBinsHz,
            headphone: headphone,
            headphoneCurve: headphoneCurve,
            reference: reference
        ) else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noCommonFrequencyCoverage,
                message: "A curve value could not be interpolated across the common detail range."
            )
        }

        let widths = binWidths(
            frequencies: features.frequencyBinsHz,
            indices: bins,
            lowerBound: minimum,
            upperBound: maximum
        )
        let detailWidths = binWidths(
            frequencies: features.frequencyBinsHz,
            indices: detailBins,
            lowerBound: detailMinimum,
            upperBound: detailMaximum
        )
        let detailTotalEnergy = totalEnergy(
            features: features,
            bins: detailBins,
            widths: detailWidths
        )
        var totalEnergy = 0.0
        var highEnergy = 0.0
        var weightedDelta = 0.0
        var frameContributions: [(weight: Double, value: Double)] = []
        var bandEnergyByFrame: [[Double]] = []

        for frame in features.frames {
            let powers = averagedPower(frame: frame, channelCount: features.channelCount, indices: bins)
            guard powers.count == bins.count else { continue }
            let energies = zip(powers, widths).map { power, width in
                max(0, power) * width
            }
            let frameEnergy = energies.reduce(0, +)
            guard frameEnergy.isFinite, frameEnergy > 0 else { continue }
            totalEnergy += frameEnergy
            weightedDelta += zip(energies, deltas).reduce(0) { $0 + $1.0 * $1.1 }

            // C keeps the stereo channels as separate dimensions. D is
            // channel-linear and can use the averaged PSD above; JS over an
            // averaged stereo spectrum would otherwise hide left/right
            // differences before measuring the audible change.
            let channelPowerArrays = channelPowers(
                frame: frame,
                channelCount: features.channelCount,
                indices: bins
            )
            let channelEnergies = channelPowerArrays.flatMap { powers in
                zip(powers, widths).map { max(0, $0.0) * $0.1 }
            }
            let cFrameEnergy = channelEnergies.reduce(0, +)
            let cDeltas = Array(repeating: deltas, count: channelPowerArrays.count).flatMap { $0 }
            let q = zip(channelEnergies, cDeltas).map { energy, delta in
                energy * safeGain(forDecibels: delta)
            }
            let qTotal = q.reduce(0, +)
            if cFrameEnergy.isFinite, cFrameEnergy > 0, qTotal.isFinite, qTotal > 0 {
                let pDistribution = channelEnergies.map { $0 / cFrameEnergy }
                let qDistribution = q.map { $0 / qTotal }
                let js = jsDivergence(p: pDistribution, q: qDistribution)
                if js.isFinite {
                    frameContributions.append((cFrameEnergy, js))
                }
            }
            if let highStart = bins.firstIndex(where: { features.frequencyBinsHz[$0] >= configuration.highFrequencyMinimumHz }),
               let highEnd = bins.lastIndex(where: { features.frequencyBinsHz[$0] <= configuration.highFrequencyMaximumHz }),
               highStart <= highEnd {
                for localIndex in highStart...highEnd {
                    highEnergy += energies[localIndex]
                }
            }
            bandEnergyByFrame.append(energies)
        }

        guard totalEnergy.isFinite, totalEnergy > 0 else {
            return unevaluable(
                features: features,
                headphone: headphone,
                reference: reference,
                reason: .noSpectrumFrames,
                message: "The common frequency range contains no finite non-zero audio energy."
            )
        }

        let globalGain = weightedDelta / totalEnergy
        var variance = 0.0
        for frameEnergies in bandEnergyByFrame {
            for (index, energy) in frameEnergies.enumerated() {
                variance += energy * pow(deltas[index] - globalGain, 2)
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

        let highRangeIsComplete = minimum <= configuration.highFrequencyMinimumHz
            && maximum >= configuration.highFrequencyMaximumHz
        let highRatio = highEnergy / totalEnergy
        let dHigh: Double?
        if highRangeIsComplete, highRatio >= configuration.minimumHighEnergyRatio {
            var highWeightedVariance = 0.0
            var highTotal = 0.0
            for frame in features.frames {
                let powers = averagedPower(frame: frame, channelCount: features.channelCount, indices: bins)
                let energies = zip(powers, widths).map { max(0, $0.0) * $0.1 }
                for (index, energy) in energies.enumerated() {
                    let frequency = features.frequencyBinsHz[bins[index]]
                    guard frequency >= configuration.highFrequencyMinimumHz,
                          frequency <= configuration.highFrequencyMaximumHz else { continue }
                    highTotal += energy
                    highWeightedVariance += energy * pow(deltas[index] - globalGain, 2)
                }
            }
            dHigh = highTotal > 0 ? sqrt(max(0, highWeightedVariance / highTotal)) : nil
        } else {
            dHigh = nil
        }

        let evidence = makeEvidence(
            features: features,
            bands: FrequencyBand.expanded(through: detailMaximum),
            bins: detailBins,
            frequencies: features.frequencyBinsHz,
            deltas: detailDeltas,
            totalEnergy: detailTotalEnergy,
            globalGain: globalGain,
            commonMinimum: detailMinimum,
            commonMaximum: detailMaximum
        )

        return MatchResult(
            recordingID: features.recordingID,
            headphoneID: headphone.id,
            referenceID: reference.id,
            status: features.coverage.kind == .complete && !features.coverage.hasUnexplainedGaps ? .evaluated : .partial,
            c: c,
            d: d,
            dHigh: dHigh,
            highFrequencyEnergyRatio: highRatio,
            evaluatedMinHz: minimum,
            evaluatedMaxHz: maximum,
            frequencyValidity: features.frequencyValidity,
            completeOrPartial: features.coverage.kind,
            frequencyBands: evidence,
            modelVersion: configuration.modelVersion
        )
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
            modelVersion: configuration.modelVersion
        )
    }

    private func averagedPower(frame: SpectrumFrame, channelCount: Int, indices: [Int]) -> [Double] {
        let allChannels = channelPowers(frame: frame, channelCount: channelCount, indices: indices)
        guard !allChannels.isEmpty else { return [] }
        return indices.indices.map { index in
            let values: [Double] = allChannels.compactMap { channel -> Double? in
                guard index < channel.count else { return nil }
                return channel[index]
            }
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }
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

    private func deltaValues(
        bins: [Int],
        frequencies: [Double],
        headphone: Headphone,
        headphoneCurve: Curve,
        reference: Curve
    ) -> [Double]? {
        let values = bins.map { index -> Double in
            let frequency = frequencies[index]
            let left = headphoneCurve.value(at: frequency)
            let headphoneDB: Double?
            if let rightCurve = headphone.rightCurve {
                guard let left, let right = rightCurve.value(at: frequency) else {
                    return .nan
                }
                headphoneDB = (left + right) / 2
            } else {
                headphoneDB = left
            }
            guard let headphoneDB, let referenceDB = reference.value(at: frequency) else {
                return .nan
            }
            var delta = headphoneDB - referenceDB
            if let eqCurve = headphone.eqCurve {
                guard let eqValue = eqCurve.value(at: frequency) else { return .nan }
                delta += eqValue
            }
            return delta
        }
        return values.allSatisfy(\.isFinite) ? values : nil
    }

    private func totalEnergy(features: SpectrumFeatures, bins: [Int], widths: [Double]) -> Double {
        var result = 0.0
        for frame in features.frames {
            let powers = averagedPower(frame: frame, channelCount: features.channelCount, indices: bins)
            result += zip(powers, widths).reduce(0) { partial, pair in
                let value = pair.0.isFinite && pair.0 >= 0 ? pair.0 : 0
                return partial + value * pair.1
            }
        }
        return result.isFinite ? result : 0
    }

    private func binWidths(
        frequencies: [Double],
        indices: [Int],
        lowerBound: Double,
        upperBound: Double
    ) -> [Double] {
        indices.map { index in
            let cellLower: Double
            if index == 0 {
                cellLower = frequencies[index]
            } else {
                cellLower = (frequencies[index - 1] + frequencies[index]) / 2
            }
            let cellUpper: Double
            if index == frequencies.count - 1 {
                cellUpper = frequencies[index]
            } else {
                cellUpper = (frequencies[index] + frequencies[index + 1]) / 2
            }
            let lower = max(cellLower, lowerBound)
            let upper = min(cellUpper, upperBound)
            let width = upper - lower
            return width.isFinite && width > 0 ? width : 1
        }
    }

    private func cellOverlapWidth(frequencies: [Double], index: Int, lower: Double, upper: Double) -> Double {
        let cellLower: Double
        if index == 0 {
            cellLower = frequencies[index]
        } else {
            cellLower = (frequencies[index - 1] + frequencies[index]) / 2
        }
        let cellUpper: Double
        if index == frequencies.count - 1 {
            cellUpper = frequencies[index]
        } else {
            cellUpper = (frequencies[index] + frequencies[index + 1]) / 2
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
        deltas: [Double],
        totalEnergy: Double,
        globalGain: Double,
        commonMinimum: Double,
        commonMaximum: Double
    ) -> [MatchBandEvidence] {
        bands.map { band in
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

            var bandEnergy = 0.0
            var weightedDelta = 0.0
            var weightedVariance = 0.0
            var peakEnergy = 0.0
            var peakTime: Double?
            for frame in features.frames {
                let powers = averagedPower(frame: frame, channelCount: features.channelCount, indices: bins)
                var frameBandEnergy = 0.0
                for (localIndex, index) in bins.enumerated() {
                    let overlap = cellOverlapWidth(frequencies: frequencies, index: index, lower: lower, upper: upper)
                    guard overlap > 0 else { continue }
                    let energy = max(0, powers[localIndex]) * overlap
                    frameBandEnergy += energy
                    bandEnergy += energy
                    weightedDelta += energy * deltas[localIndex]
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
            let meanDelta = weightedDelta / bandEnergy
            for frame in features.frames {
                let powers = averagedPower(frame: frame, channelCount: features.channelCount, indices: bins)
                for (localIndex, index) in bins.enumerated() {
                    let overlap = cellOverlapWidth(frequencies: frequencies, index: index, lower: lower, upper: upper)
                    guard overlap > 0 else { continue }
                    let energy = max(0, powers[localIndex]) * overlap
                    weightedVariance += energy * pow(deltas[localIndex] - globalGain, 2)
                }
            }
            let isPartial = lower > band.lowerHz || upper < band.upperHz
            let frequencyResolution = features.sampleRate / Double(features.parameters.frameLength)
            let isResolutionLimited = frequencyResolution.isFinite
                && frequencyResolution > 0
                && (upper - lower) < frequencyResolution
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

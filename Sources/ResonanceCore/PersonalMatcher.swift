import Foundation

/// Evidence for one auditory/display frequency band.
public struct PersonalBandEvidence: Sendable, Equatable, Identifiable {
    public let id: String
    public let lowerHz: Double
    public let upperHz: Double
    public let isHighFrequency: Bool
    public let isExtendedFrequency: Bool
    public let measuredEnergyFraction: Double?
    public let deviationDB: Double?
    public let peakTimeSeconds: Double?
    public let state: State
    public let note: String?

    public enum State: String, Sendable, Equatable {
        case evaluated
        case partialSupport
        case noAudioContent
        case outsideSupport
        case insufficientResolution
    }

    public init(
        lowerHz: Double,
        upperHz: Double,
        isHighFrequency: Bool = false,
        isExtendedFrequency: Bool = false,
        measuredEnergyFraction: Double? = nil,
        deviationDB: Double? = nil,
        peakTimeSeconds: Double? = nil,
        state: State,
        note: String? = nil
    ) {
        self.id = "\(lowerHz)-\(upperHz)"
        self.lowerHz = lowerHz
        self.upperHz = upperHz
        self.isHighFrequency = isHighFrequency
        self.isExtendedFrequency = isExtendedFrequency
        self.measuredEnergyFraction = measuredEnergyFraction
        self.deviationDB = deviationDB
        self.peakTimeSeconds = peakTimeSeconds
        self.state = state
        self.note = note
    }
}

public struct PersonalReferenceMatch: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let referenceID: UUID
    public let referenceName: String
    /// RMS residual in dB after one global level offset is fitted for this
    /// reference over the shared 20 Hz–20 kHz ranking range.
    public let overallDeviationDB: Double?
    /// RMS residual in 10–20 kHz, using the same global offset as overall.
    public let highFrequencyDeviationDB: Double?
    public let frameErrorP90DB: Double?
    public let worstFrameErrorDB: Double?
    public let worstFrameStartTimeSeconds: Double?
    /// The fitted offset is diagnostic, not a subjective quality score.
    public let globalLevelOffsetDB: Double?
    public let evaluatedMinHz: Double?
    public let evaluatedMaxHz: Double?
    public let status: Status
    public let frequencyEvidence: [PersonalBandEvidence]
    public let limitations: [String]

    public enum Status: String, Sendable, Equatable {
        case evaluated
        case partial
        case noAudioContent
        case unavailable
    }

    public init(
        referenceID: UUID,
        referenceName: String,
        overallDeviationDB: Double? = nil,
        highFrequencyDeviationDB: Double? = nil,
        frameErrorP90DB: Double? = nil,
        worstFrameErrorDB: Double? = nil,
        worstFrameStartTimeSeconds: Double? = nil,
        globalLevelOffsetDB: Double? = nil,
        evaluatedMinHz: Double? = nil,
        evaluatedMaxHz: Double? = nil,
        status: Status,
        frequencyEvidence: [PersonalBandEvidence] = [],
        limitations: [String] = []
    ) {
        self.id = referenceID
        self.referenceID = referenceID
        self.referenceName = referenceName
        self.overallDeviationDB = overallDeviationDB
        self.highFrequencyDeviationDB = highFrequencyDeviationDB
        self.frameErrorP90DB = frameErrorP90DB
        self.worstFrameErrorDB = worstFrameErrorDB
        self.worstFrameStartTimeSeconds = worstFrameStartTimeSeconds
        self.globalLevelOffsetDB = globalLevelOffsetDB
        self.evaluatedMinHz = evaluatedMinHz
        self.evaluatedMaxHz = evaluatedMaxHz
        self.status = status
        self.frequencyEvidence = frequencyEvidence
        self.limitations = limitations
    }

    // Short read-only aliases for UI/harness callers.
    public var overallDB: Double? { overallDeviationDB }
    public var highDB: Double? { highFrequencyDeviationDB }
    public var frameP90DB: Double? { frameErrorP90DB }
    public var worstFrameDB: Double? { worstFrameErrorDB }
    public var worstFrameTimeSeconds: Double? { worstFrameStartTimeSeconds }
    public var bandEvidence: [PersonalBandEvidence] { frequencyEvidence }
}

public struct PersonalMatchResult: Sendable, Equatable {
    public let matches: [PersonalReferenceMatch]
    public let bestReferenceID: UUID?
    public let modelVersion: String
    public let commonMinimumHz: Double?
    public let commonMaximumHz: Double?
    public let limitations: [String]

    public init(
        matches: [PersonalReferenceMatch],
        bestReferenceID: UUID?,
        modelVersion: String,
        commonMinimumHz: Double? = nil,
        commonMaximumHz: Double? = nil,
        limitations: [String] = []
    ) {
        self.matches = matches
        self.bestReferenceID = bestReferenceID
        self.modelVersion = modelVersion
        self.commonMinimumHz = commonMinimumHz
        self.commonMaximumHz = commonMaximumHz
        self.limitations = limitations
    }
}

/// Matches one headphone's measured FR against each supplied reference using
/// recorded per-frame PSD.  The calculation is deliberately descriptive: no
/// subjective 0–100 score, semantic labels, ML, or ISO loudness model is used.
public struct PersonalMatcher: Sendable {
    public static let modelVersion = "personal-v1-glasberg-moore-band-power"

    public struct Configuration: Sendable, Equatable {
        public let compressionExponent: Double

        public init(compressionExponent: Double = 0.3) {
            self.compressionExponent = compressionExponent
        }

        public var isValid: Bool {
            compressionExponent.isFinite && compressionExponent > 0 && compressionExponent <= 1
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func match(
        features: SpectrumFeatures,
        headphone: Headphone,
        references: [Curve]
    ) -> PersonalMatchResult {
        let commonLimitations = baseLimitations(features: features, references: references)
        guard configuration.isValid else {
            let limitation = "compressionExponent 必须满足 0 < alpha ≤ 1，当前值无效。"
            return PersonalMatchResult(
                matches: references.map { unavailableMatch(reference: $0, limitations: commonLimitations + [limitation]) },
                bestReferenceID: nil,
                modelVersion: Self.modelVersion,
                limitations: commonLimitations + [limitation]
            )
        }
        guard !references.isEmpty else {
            return PersonalMatchResult(
                matches: [],
                bestReferenceID: nil,
                modelVersion: Self.modelVersion,
                limitations: commonLimitations + ["没有提供参考曲线。"]
            )
        }
        guard let headphoneCurve = headphone.curve else {
            let limitation = "缺少耳机实测曲线。"
            return PersonalMatchResult(
                matches: references.map { unavailableMatch(reference: $0, limitations: commonLimitations + [limitation]) },
                bestReferenceID: nil,
                modelVersion: Self.modelVersion,
                limitations: commonLimitations + [limitation]
            )
        }
        guard validFeatureShape(features) else {
            let limitation = "频率网格或逐声道 PSD 形状无效，无法计算。"
            return PersonalMatchResult(
                matches: references.map { unavailableMatch(reference: $0, limitations: commonLimitations + [limitation]) },
                bestReferenceID: nil,
                modelVersion: Self.modelVersion,
                limitations: commonLimitations + [limitation]
            )
        }
        guard let support = commonSupport(
            features: features,
            headphoneCurve: headphoneCurve,
            rightCurve: headphone.rightCurve,
            eqCurve: headphone.eqCurve,
            references: references
        ) else {
            let limitation = "耳机、所有参考曲线与录音没有共同频段。"
            return PersonalMatchResult(
                matches: references.map { unavailableMatch(reference: $0, limitations: commonLimitations + [limitation]) },
                bestReferenceID: nil,
                modelVersion: Self.modelVersion,
                limitations: commonLimitations + [limitation]
            )
        }

        let definitions = makeBands(through: support.upperHz)
        let prepared = prepareBands(
            features: features,
            support: support,
            definitions: definitions,
            headphone: headphone,
            headphoneCurve: headphoneCurve
        )
        let rankingUpper = min(support.upperHz, 20_000)

        // The spectral grid, band overlaps, integrated PSD energies, and
        // headphone interpolation are shared by every reference. A reference
        // only needs one response lookup per FFT bin and then a compact
        // frame×channel×band pass.
        let matches = references.map { reference in
            evaluate(
                reference: reference,
                features: features,
                support: support,
                definitions: definitions,
                prepared: prepared,
                rankingUpper: rankingUpper,
                commonLimitations: commonLimitations
            )
        }
        let bestReferenceID = matches
            .filter { $0.overallDeviationDB?.isFinite == true }
            .min { lhs, rhs in
                guard let left = lhs.overallDeviationDB, let right = rhs.overallDeviationDB else {
                    return lhs.overallDeviationDB != nil
                }
                if left == right { return lhs.referenceID.uuidString < rhs.referenceID.uuidString }
                return left < right
            }?.referenceID

        return PersonalMatchResult(
            matches: matches,
            bestReferenceID: bestReferenceID,
            modelVersion: Self.modelVersion,
            commonMinimumHz: support.lowerHz,
            commonMaximumHz: support.upperHz,
            limitations: commonLimitations + support.limitations
        )
    }

    private struct CommonSupport {
        let lowerHz: Double
        let upperHz: Double
        let limitations: [String]
    }

    private struct BandDefinition {
        let lowerHz: Double
        let upperHz: Double
        let isHighFrequency: Bool
        let isExtendedFrequency: Bool
        let note: String?

        var isRankingBand: Bool { lowerHz < 20_000 && upperHz > 20 }
    }

    private struct BinOverlap {
        let index: Int
        let widthHz: Double
    }

    private struct BandPlan {
        let definition: BandDefinition
        let overlaps: [BinOverlap]
        let isRankingBand: Bool
        let resolutionLimited: Bool
    }

    /// One compact observation: one frame, one channel, one auditory band.
    private struct BandBaseObservation {
        let frameIndex: Int
        let startTimeSeconds: Double
        let bandIndex: Int
        let channelIndex: Int
        let energy: Double
        let frameWeight: Double
        let spectralWeight: Double
    }

    private struct PreparedBands {
        let plans: [BandPlan]
        let observations: [BandBaseObservation]
        let totalMainEnergy: Double
        let totalAllEnergy: Double
        let headphoneValues: [[Double?]]
    }

    private struct ReferenceBandObservation {
        let base: BandBaseObservation
        let deviationDB: Double?
        let responseEnergy: Double
    }

    private struct FrameError {
        let startTimeSeconds: Double
        let errorDB: Double
        let weight: Double
    }

    private func evaluate(
        reference: Curve,
        features: SpectrumFeatures,
        support: CommonSupport,
        definitions: [BandDefinition],
        prepared: PreparedBands,
        rankingUpper: Double,
        commonLimitations: [String]
    ) -> PersonalReferenceMatch {
        let referenceValues = features.frequencyBinsHz.map { reference.value(at: $0) }
        let responseObservations = makeReferenceObservations(
            features: features,
            referenceValues: referenceValues,
            prepared: prepared,
            headphoneValues: prepared.headphoneValues
        )
        let ranking = responseObservations.filter { observation in
            let definition = definitions[observation.base.bandIndex]
            return definition.isRankingBand &&
                definition.lowerHz < rankingUpper &&
                observation.deviationDB != nil
        }
        let usableRanking = ranking.filter { $0.base.energy > 0 && $0.base.frameWeight * $0.base.spectralWeight > 0 }
        let rankingWeight = usableRanking.reduce(0) { $0 + $1.base.frameWeight * $1.base.spectralWeight }

        guard prepared.totalMainEnergy > 0, rankingWeight.isFinite, rankingWeight > 0 else {
            let limitation = prepared.totalMainEnergy > 0
                ? "参考曲线在共同频段没有可用的逐带响应。"
                : "录音频谱在 20 Hz–20 kHz 没有真实能量；不生成 0 dB 最佳结果。"
            return PersonalReferenceMatch(
                referenceID: reference.id,
                referenceName: reference.name,
                evaluatedMinHz: support.lowerHz,
                evaluatedMaxHz: rankingUpper >= support.lowerHz ? rankingUpper : nil,
                status: prepared.totalMainEnergy > 0 ? .unavailable : .noAudioContent,
                frequencyEvidence: makeBandEvidence(
                    definitions: definitions,
                    plans: prepared.plans,
                    observations: responseObservations,
                    globalGain: nil,
                    totalAllEnergy: prepared.totalAllEnergy,
                    support: support
                ),
                limitations: commonLimitations + [limitation]
            )
        }

        // Fit one g per reference from the compact band observations. It is
        // reused for every frame and every frequency band, including 10–20k.
        let globalGain = weightedMean(
            usableRanking.compactMap { observation in
                guard let deviationDB = observation.deviationDB else { return nil }
                return (deviationDB, observation.base.frameWeight * observation.base.spectralWeight)
            }
        )
        let overall = weightedRMS(
            usableRanking.compactMap { observation in
                guard let deviationDB = observation.deviationDB else { return nil }
                return (deviationDB - globalGain, observation.base.frameWeight * observation.base.spectralWeight)
            }
        )
        let high = weightedRMS(
            usableRanking.compactMap { observation in
                let definition = definitions[observation.base.bandIndex]
                guard definition.isHighFrequency, let deviationDB = observation.deviationDB else { return nil }
                return (deviationDB - globalGain, observation.base.frameWeight * observation.base.spectralWeight)
            }
        )
        let frameErrors = makeFrameErrors(
            observations: ranking,
            definitions: definitions,
            globalGain: globalGain
        )
        // P90 uses the same compressed frame-energy weights as the match. A
        // tail of near-silent frames therefore cannot dominate the percentile.
        let frameP90 = weightedPercentile(frameErrors.map { ($0.errorDB, $0.weight) }, 0.9)
        let worst = frameErrors.max {
            if $0.errorDB == $1.errorDB { return $0.startTimeSeconds > $1.startTimeSeconds }
            return $0.errorDB < $1.errorDB
        }

        var limitations = commonLimitations
        if support.lowerHz > 20 || rankingUpper < 20_000 {
            limitations.append("排名仅使用共同支持范围 \(formatHz(support.lowerHz))–\(formatHz(rankingUpper)) Hz。")
        }
        if responseObservations.contains(where: { $0.base.energy > $0.responseEnergy * 1.000001 }) {
            limitations.append("部分频带的 PSD 没有对应的完整曲线插值，结果使用可用交集。")
        }
        let status: PersonalReferenceMatch.Status = commonLimitations.contains { $0.contains("覆盖") }
            ? .partial
            : .evaluated

        return PersonalReferenceMatch(
            referenceID: reference.id,
            referenceName: reference.name,
            overallDeviationDB: overall,
            highFrequencyDeviationDB: high,
            frameErrorP90DB: frameP90,
            worstFrameErrorDB: worst?.errorDB,
            worstFrameStartTimeSeconds: worst?.startTimeSeconds,
            globalLevelOffsetDB: globalGain,
            evaluatedMinHz: support.lowerHz,
            evaluatedMaxHz: rankingUpper,
            status: status,
            frequencyEvidence: makeBandEvidence(
                definitions: definitions,
                plans: prepared.plans,
                observations: responseObservations,
                globalGain: globalGain,
                totalAllEnergy: prepared.totalAllEnergy,
                support: support
            ),
            limitations: limitations
        )
    }

    private func prepareBands(
        features: SpectrumFeatures,
        support: CommonSupport,
        definitions: [BandDefinition],
        headphone: Headphone,
        headphoneCurve: Curve
    ) -> PreparedBands {
        let frequencies = features.frequencyBinsHz
        let plans = definitions.map { definition in
            let overlaps = frequencies.indices.compactMap { index -> BinOverlap? in
                let frequency = frequencies[index]
                let lower = max(support.lowerHz, definition.lowerHz)
                let upper = min(support.upperHz, definition.upperHz)
                // Mask only the global support and the audible/extension
                // partition. The band itself is clipped by cellOverlapWidth:
                // a cell whose centre is near an ERB boundary contributes its
                // valid half to each adjacent band instead of disappearing.
                guard frequency >= support.lowerHz, frequency <= support.upperHz else { return nil }
                if definition.isExtendedFrequency {
                    guard frequency > 20_000 else { return nil }
                } else {
                    guard frequency <= 20_000 else { return nil }
                }
                let width = cellOverlapWidth(
                    frequencies: frequencies,
                    index: index,
                    lower: lower,
                    upper: upper
                )
                return width > 0 ? BinOverlap(index: index, widthHz: width) : nil
            }
            return BandPlan(
                definition: definition,
                overlaps: overlaps,
                isRankingBand: definition.lowerHz < 20_000 && definition.upperHz > 20,
                resolutionLimited: max(0, min(support.upperHz, definition.upperHz) - max(support.lowerHz, definition.lowerHz)) > 0 &&
                    max(0, min(support.upperHz, definition.upperHz) - max(support.lowerHz, definition.lowerHz)) <
                    features.sampleRate / Double(features.parameters.frameLength)
            )
        }
        var raw: [(frame: Int, start: Double, band: Int, channel: Int, energy: Double)] = []
        raw.reserveCapacity(features.frames.count * features.channelCount * max(1, definitions.count))
        for (frameIndex, frame) in features.frames.enumerated() {
            for (bandIndex, plan) in plans.enumerated() {
                for channelIndex in 0..<features.channelCount {
                    let energy = plan.overlaps.reduce(0.0) { partial, overlap in
                        let psd = frame.powerSpectralDensityByChannel[channelIndex][overlap.index]
                        return partial + max(0, psd) * overlap.widthHz
                    }
                    raw.append((frameIndex, frame.startTimeSeconds, bandIndex, channelIndex, energy))
                }
            }
        }
        var mainFrameEnergy = Array(repeating: 0.0, count: features.frames.count)
        for value in raw where plans[value.band].isRankingBand {
            mainFrameEnergy[value.frame] += value.energy
        }
        let totalMainEnergy = mainFrameEnergy.reduce(0, +)
        let totalAllEnergy = raw.reduce(0) { $0 + $1.energy }
        var frameSpectralWeightSum = Array(repeating: 0.0, count: features.frames.count)
        if totalMainEnergy > 0 {
            for value in raw where plans[value.band].isRankingBand {
                let frameEnergy = mainFrameEnergy[value.frame]
                if frameEnergy > 0, value.energy > 0 {
                    frameSpectralWeightSum[value.frame] += pow(value.energy / frameEnergy, configuration.compressionExponent)
                }
            }
        }
        var observations: [BandBaseObservation] = []
        observations.reserveCapacity(raw.count)
        for value in raw {
            let frameEnergy = mainFrameEnergy[value.frame]
            let frameWeight = totalMainEnergy > 0 && frameEnergy > 0
                ? pow(frameEnergy / totalMainEnergy, configuration.compressionExponent)
                : 0
            let rawSpectralWeight = frameEnergy > 0 && value.energy > 0
                ? pow(value.energy / frameEnergy, configuration.compressionExponent)
                : 0
            let spectralWeight: Double
            if plans[value.band].isRankingBand {
                let normalizer = frameSpectralWeightSum[value.frame]
                spectralWeight = normalizer > 0 ? rawSpectralWeight / normalizer : 0
            } else {
                // Extended bands may be shown as evidence, but never enter
                // the 20 Hz–20 kHz frame spectral normalizer.
                spectralWeight = rawSpectralWeight
            }
            observations.append(
                BandBaseObservation(
                    frameIndex: value.frame,
                    startTimeSeconds: value.start,
                    bandIndex: value.band,
                    channelIndex: value.channel,
                    energy: value.energy,
                    frameWeight: frameWeight,
                    spectralWeight: spectralWeight
                )
            )
        }
        return PreparedBands(
            plans: plans,
            observations: observations,
            totalMainEnergy: totalMainEnergy,
            totalAllEnergy: totalAllEnergy,
            headphoneValues: makeHeadphoneResponseCache(
                features: features,
                support: support,
                headphone: headphone,
                fallbackCurve: headphoneCurve
            )
        )
    }

    private func makeReferenceObservations(
        features: SpectrumFeatures,
        referenceValues: [Double?],
        prepared: PreparedBands,
        headphoneValues: [[Double?]]
    ) -> [ReferenceBandObservation] {
        // Curves are interpolated once per FFT bin. The headphone values are
        // stored on the compact band pass's frequency-independent response
        // cache below; no FFT-bin-sized observation matrix is retained.
        var maximumDeltaDB = -Double.infinity
        for channelValues in headphoneValues {
            for index in features.frequencyBinsHz.indices {
                guard let headphoneDB = channelValues[index], let referenceDB = referenceValues[index] else { continue }
                let delta = headphoneDB - referenceDB
                if delta.isFinite { maximumDeltaDB = max(maximumDeltaDB, delta) }
            }
        }
        if !maximumDeltaDB.isFinite { maximumDeltaDB = 0 }
        let relativeGains: [[Double?]] = headphoneValues.map { channelValues in
            channelValues.enumerated().map { index, headphoneDB in
                guard let headphoneDB, let referenceDB = referenceValues[index] else { return nil }
                let delta = headphoneDB - referenceDB
                guard delta.isFinite else { return nil }
                let gain = pow(10, (delta - maximumDeltaDB) / 10)
                return gain.isFinite && gain > 0 ? gain : nil
            }
        }

        var result: [ReferenceBandObservation] = []
        result.reserveCapacity(prepared.observations.count)
        for base in prepared.observations {
            let plan = prepared.plans[base.bandIndex]
            var responseEnergy = 0.0
            var responsePower = 0.0
            guard !headphoneValues.isEmpty else {
                result.append(ReferenceBandObservation(base: base, deviationDB: nil, responseEnergy: 0))
                continue
            }
            let channel = min(base.channelIndex, headphoneValues.count - 1)
            for overlap in plan.overlaps {
                let psd = features.frames[base.frameIndex].powerSpectralDensityByChannel[base.channelIndex][overlap.index]
                let energy = max(0, psd) * overlap.widthHz
                guard energy > 0,
                      let ratio = relativeGains[channel][overlap.index] else { continue }
                responseEnergy += energy
                responsePower += energy * ratio
            }
            let deviation: Double?
            if responseEnergy > 0, responsePower > 0 {
                let ratio = responsePower / responseEnergy
                deviation = ratio.isFinite && ratio > 0 ? 10 * log10(ratio) + maximumDeltaDB : nil
            } else {
                deviation = nil
            }
            result.append(
                ReferenceBandObservation(
                    base: base,
                    deviationDB: deviation,
                    responseEnergy: responseEnergy
                )
            )
        }
        return result
    }

    private func makeBandEvidence(
        definitions: [BandDefinition],
        plans: [BandPlan],
        observations: [ReferenceBandObservation],
        globalGain: Double?,
        totalAllEnergy: Double,
        support: CommonSupport
    ) -> [PersonalBandEvidence] {
        definitions.enumerated().map { bandIndex, definition in
            let lower = max(definition.lowerHz, support.lowerHz)
            let upper = min(definition.upperHz, support.upperHz)
            guard lower < upper else {
                return PersonalBandEvidence(
                    lowerHz: definition.lowerHz,
                    upperHz: definition.upperHz,
                    isHighFrequency: definition.isHighFrequency,
                    isExtendedFrequency: definition.isExtendedFrequency,
                    state: .outsideSupport,
                    note: definition.note
                )
            }
            let bandObservations = observations.filter { $0.base.bandIndex == bandIndex }
            let rawEnergy = bandObservations.reduce(0) { $0 + $1.base.energy }
            let responseEnergy = bandObservations.reduce(0) { $0 + $1.responseEnergy }
            let fraction = totalAllEnergy > 0 ? rawEnergy / totalAllEnergy : nil
            var frameEnergies: [Int: Double] = [:]
            for observation in bandObservations {
                frameEnergies[observation.base.frameIndex, default: 0] += observation.base.energy
            }
            let peakFrame = frameEnergies.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }?.key
            let peakTime = peakFrame.flatMap { frame in
                bandObservations.first(where: { $0.base.frameIndex == frame })?.base.startTimeSeconds
            }
            let bandWeight = bandObservations.reduce(0) { $0 + $1.base.frameWeight * $1.base.spectralWeight }
            let deviation = globalGain.flatMap { gain in
                weightedRMS(
                    bandObservations.compactMap { observation in
                        guard let value = observation.deviationDB else { return nil }
                        return (value - gain, observation.base.frameWeight * observation.base.spectralWeight)
                    }
                )
            }
            let clipped = lower > definition.lowerHz || upper < definition.upperHz
            let state: PersonalBandEvidence.State
            if plans[bandIndex].overlaps.isEmpty {
                state = .insufficientResolution
            } else if plans[bandIndex].resolutionLimited {
                state = .insufficientResolution
            } else if rawEnergy <= 0 {
                state = .noAudioContent
            } else if globalGain == nil || bandWeight <= 0 {
                state = definition.isExtendedFrequency ? .partialSupport : .noAudioContent
            } else if responseEnergy + 1e-12 < rawEnergy {
                state = .partialSupport
            } else {
                state = clipped ? .partialSupport : .evaluated
            }
            return PersonalBandEvidence(
                lowerHz: definition.lowerHz,
                upperHz: definition.upperHz,
                isHighFrequency: definition.isHighFrequency,
                isExtendedFrequency: definition.isExtendedFrequency,
                measuredEnergyFraction: fraction,
                deviationDB: bandWeight > 0 ? deviation : nil,
                peakTimeSeconds: peakTime,
                state: state,
                note: definition.note
            )
        }
    }

    private func commonSupport(
        features: SpectrumFeatures,
        headphoneCurve: Curve,
        rightCurve: Curve?,
        eqCurve: Curve?,
        references: [Curve]
    ) -> CommonSupport? {
        var lower = max(20, features.validMinHz, headphoneCurve.validMinHz)
        var upper = min(features.validMaxHz, headphoneCurve.validMaxHz)
        if let rightCurve {
            lower = max(lower, rightCurve.validMinHz)
            upper = min(upper, rightCurve.validMaxHz)
        }
        if let eqCurve {
            lower = max(lower, eqCurve.validMinHz)
            upper = min(upper, eqCurve.validMaxHz)
        }
        for reference in references {
            lower = max(lower, reference.validMinHz)
            upper = min(upper, reference.validMaxHz)
        }
        guard lower.isFinite, upper.isFinite, lower < upper else { return nil }
        var limitations: [String] = []
        if references.count > 1 {
            limitations.append("多参考使用全部参考曲线共同支持范围，未跨参考拼接频段。")
        }
        if upper > 20_000 {
            limitations.append("20 kHz 以上仅作为扩展频段明细，不参与最佳参考选择，也不默认为可听收益。")
        }
        return CommonSupport(lowerHz: lower, upperHz: upper, limitations: limitations)
    }

    private func makeBands(through maximumHz: Double) -> [BandDefinition] {
        var result: [BandDefinition] = []
        var lower = 20.0
        while lower < min(10_000, maximumHz) {
            let upper = min(min(10_000, maximumHz), lower + glasbergMooreERBWidth(at: lower))
            guard upper > lower else { break }
            result.append(
                BandDefinition(
                    lowerHz: lower,
                    upperHz: upper,
                    isHighFrequency: false,
                    isExtendedFrequency: false,
                    note: "20 Hz–10 kHz：Glasberg–Moore ERB 宽度"
                )
            )
            lower = upper
        }
        let upperHigh = min(20_000, maximumHz)
        let engineeringEdges = [10_000.0, 12_500, 16_000, 20_000]
        for pair in zip(engineeringEdges, engineeringEdges.dropFirst()) {
            guard pair.0 < upperHigh else { continue }
            result.append(
                BandDefinition(
                    lowerHz: pair.0,
                    upperHz: min(pair.1, upperHigh),
                    isHighFrequency: true,
                    isExtendedFrequency: false,
                    note: "10–20 kHz：较宽的工程扩展带，不等同于 ISO 听阈模型"
                )
            )
        }
        guard maximumHz > 20_000 else { return result }
        let extensionEdges = [20_000.0, 25_000, 31_500, 40_000, 50_000, 63_000, 80_000, 100_000]
        for pair in zip(extensionEdges, extensionEdges.dropFirst()) where pair.0 < maximumHz {
            result.append(
                BandDefinition(
                    lowerHz: pair.0,
                    upperHz: min(pair.1, maximumHz),
                    isHighFrequency: false,
                    isExtendedFrequency: true,
                    note: ">20 kHz：扩展明细，不参与最佳参考选择"
                )
            )
        }
        return result
    }

    /// Glasberg–Moore ERB width in Hz, used as contiguous 20 Hz–10 kHz bands.
    private func glasbergMooreERBWidth(at frequencyHz: Double) -> Double {
        24.7 * (4.37 * frequencyHz / 1_000 + 1)
    }

    private func makeFrameErrors(
        observations: [ReferenceBandObservation],
        definitions: [BandDefinition],
        globalGain: Double
    ) -> [FrameError] {
        let grouped = Dictionary(grouping: observations) { $0.base.frameIndex }
        return grouped.compactMap { _, values in
            let main = values.filter { definitions[$0.base.bandIndex].isRankingBand }
            let error = weightedRMS(
                main.compactMap { observation in
                    guard let value = observation.deviationDB else { return nil }
                    return (value - globalGain, observation.base.spectralWeight)
                }
            )
            guard let first = values.first, let error else { return nil }
            return FrameError(
                startTimeSeconds: first.base.startTimeSeconds,
                errorDB: error,
                weight: first.base.frameWeight
            )
        }.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
    }

    private func weightedMean(_ values: [(Double, Double)]) -> Double {
        let valid = values.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > 0 }
        let totalWeight = valid.reduce(0) { $0 + $1.1 }
        guard totalWeight.isFinite, totalWeight > 0 else { return .nan }
        return valid.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight
    }

    private func weightedRMS(_ values: [(Double, Double)]) -> Double? {
        let valid = values.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > 0 }
        let totalWeight = valid.reduce(0) { $0 + $1.1 }
        guard totalWeight.isFinite, totalWeight > 0 else { return nil }
        let squared = valid.reduce(0) { $0 + $1.0 * $1.0 * $1.1 } / totalWeight
        return squared.isFinite ? sqrt(max(0, squared)) : nil
    }

    private func weightedPercentile(_ values: [(Double, Double)], _ probability: Double) -> Double? {
        let valid = values.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > 0 }.sorted { $0.0 < $1.0 }
        let totalWeight = valid.reduce(0) { $0 + $1.1 }
        guard !valid.isEmpty, totalWeight.isFinite, totalWeight > 0 else { return nil }
        let target = min(1, max(0, probability)) * totalWeight
        var cumulative = 0.0
        for value in valid {
            cumulative += value.1
            if cumulative >= target { return value.0 }
        }
        return valid.last?.0
    }

    private func validFeatureShape(_ features: SpectrumFeatures) -> Bool {
        guard features.channelCount > 0,
              features.frequencyBinsHz.count >= 2,
              features.frequencyBinsHz.allSatisfy(\.isFinite),
              zip(features.frequencyBinsHz, features.frequencyBinsHz.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            return false
        }
        return features.frames.allSatisfy { frame in
            frame.powerSpectralDensityByChannel.count == features.channelCount &&
                frame.powerSpectralDensityByChannel.allSatisfy {
                    $0.count == features.frequencyBinsHz.count && $0.allSatisfy { $0.isFinite && $0 >= 0 }
                }
        }
    }

    private func baseLimitations(features: SpectrumFeatures, references: [Curve]) -> [String] {
        var result: [String] = []
        if features.coverage.kind != .complete || features.coverage.hasUnexplainedGaps {
            result.append("录音覆盖不是完整无缺口全曲；仅使用当前已有 PSD 帧，不把缺口填成静音。")
        }
        if features.validMaxHz > 20_000 {
            result.append("20 kHz 以上只展示实际频段能量与偏差明细，不把它解释为默认可听收益。")
        }
        if references.count > 1 {
            result.append("每条参考曲线独立计算整曲偏差，最佳项不会由不同参考的频段拼接。")
        }
        result.append("频谱权重是归一化逐带功率的 \(configuration.compressionExponent) 次压缩启发式，不是 ISO 响度或听阈模型。")
        result.append("最差片段时间表示非零帧的谱形差异，不是可听性判断。")
        return result
    }

    private func unavailableMatch(reference: Curve, limitations: [String]) -> PersonalReferenceMatch {
        PersonalReferenceMatch(
            referenceID: reference.id,
            referenceName: reference.name,
            status: .unavailable,
            limitations: limitations
        )
    }

    private func makeHeadphoneResponseCache(
        features: SpectrumFeatures,
        support: CommonSupport,
        headphone: Headphone,
        fallbackCurve: Curve
    ) -> [[Double?]] {
        _ = support
        return (0..<features.channelCount).map { channelIndex in
            features.frequencyBinsHz.map { frequency in
                let curve = channelIndex == 0 ? fallbackCurve : (headphone.rightCurve ?? fallbackCurve)
                guard var value = curve.value(at: frequency) else { return nil }
                if let eqCurve = headphone.eqCurve {
                    guard let eq = eqCurve.value(at: frequency) else { return nil }
                    value += eq
                }
                return value
            }
        }
    }

    private func cellOverlapWidth(frequencies: [Double], index: Int, lower: Double, upper: Double) -> Double {
        let cellLower = index == frequencies.startIndex
            ? frequencies[index]
            : (frequencies[index - 1] + frequencies[index]) / 2
        let cellUpper = index == frequencies.index(before: frequencies.endIndex)
            ? frequencies[index]
            : (frequencies[index] + frequencies[index + 1]) / 2
        let overlap = min(cellUpper, upper) - max(cellLower, lower)
        return overlap.isFinite && overlap > 0 ? overlap : 0
    }

    private func formatHz(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.4gk", value / 1_000) : String(format: "%.4g", value)
    }
}

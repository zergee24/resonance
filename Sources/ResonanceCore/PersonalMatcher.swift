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

/// One reference's result under a sensitivity scenario.  The value is the
/// same descriptive residual used for normal ranking; it is not a liking
/// probability or a confidence interval.
public struct PersonalSensitivityReference: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let referenceID: UUID
    public let referenceName: String
    public let overallDeviationDB: Double?

    public init(
        referenceID: UUID,
        referenceName: String,
        overallDeviationDB: Double?
    ) {
        self.id = referenceID
        self.referenceID = referenceID
        self.referenceName = referenceName
        self.overallDeviationDB = overallDeviationDB
    }

    public var overallDB: Double? { overallDeviationDB }
}

/// A small, independent sensitivity scenario for the two weighting
/// heuristics in PersonalMatcher.  This describes engineering model spread;
/// it is not a statistical confidence interval or a personal-preference
/// probability.
public struct PersonalSensitivityScenario: Sendable, Equatable, Identifiable {
    public let id: String
    public let spectralExponent: Double
    public let temporalExponent: Double
    public let references: [PersonalSensitivityReference]
    public let bestReferenceID: UUID?
    public let limitations: [String]

    public init(
        id: String,
        spectralExponent: Double,
        temporalExponent: Double,
        references: [PersonalSensitivityReference],
        bestReferenceID: UUID?,
        limitations: [String]
    ) {
        self.id = id
        self.spectralExponent = spectralExponent
        self.temporalExponent = temporalExponent
        self.references = references
        self.bestReferenceID = bestReferenceID
        self.limitations = limitations
    }
}

public struct PersonalMatchResult: Sendable, Equatable {
    public let matches: [PersonalReferenceMatch]
    public let bestReferenceID: UUID?
    public let modelVersion: String
    public let commonMinimumHz: Double?
    public let commonMaximumHz: Double?
    public let limitations: [String]
    public let sensitivityDiagnostics: [PersonalSensitivityScenario]

    public init(
        matches: [PersonalReferenceMatch],
        bestReferenceID: UUID?,
        modelVersion: String,
        commonMinimumHz: Double? = nil,
        commonMaximumHz: Double? = nil,
        limitations: [String] = [],
        sensitivityDiagnostics: [PersonalSensitivityScenario] = []
    ) {
        self.matches = matches
        self.bestReferenceID = bestReferenceID
        self.modelVersion = modelVersion
        self.commonMinimumHz = commonMinimumHz
        self.commonMaximumHz = commonMaximumHz
        self.limitations = limitations
        self.sensitivityDiagnostics = sensitivityDiagnostics
    }
}

/// Matches one headphone's measured FR against each supplied reference using
/// recorded per-frame PSD.  The calculation is deliberately descriptive: no
/// subjective 0–100 score, semantic labels, ML, or ISO loudness model is used.
public struct PersonalMatcher: Sendable {
    public static let modelVersion = "personal-v2-independent-spectral-temporal-weighting"

    public struct Configuration: Sendable, Equatable {
        /// Compression of within-frame spectral band energy. This is an
        /// engineering weighting heuristic, not an ISO loudness exponent.
        public let compressionExponent: Double
        /// Compression of frame activity/energy over time. This is kept
        /// independent from the within-frame spectral weighting heuristic.
        public let temporalExponent: Double
        /// Sensitivity scenarios are diagnostics only and never affect the
        /// default match or best-reference selection.
        public let includeSensitivityDiagnostics: Bool

        /// Descriptive alias for callers that want to name the two axes
        /// explicitly; `compressionExponent` remains the source-compatible
        /// stored property.
        public var spectralExponent: Double { compressionExponent }

        /// The legacy initializer intentionally maps one alpha to both
        /// dimensions, preserving source compatibility and the old default
        /// behavior. New callers can set the two exponents independently.
        public init(
            compressionExponent: Double = 0.3,
            temporalExponent: Double? = nil,
            includeSensitivityDiagnostics: Bool = true
        ) {
            self.compressionExponent = compressionExponent
            self.temporalExponent = temporalExponent ?? compressionExponent
            self.includeSensitivityDiagnostics = includeSensitivityDiagnostics
        }

        public var isValid: Bool {
            compressionExponent.isFinite && compressionExponent > 0 && compressionExponent <= 1 &&
                temporalExponent.isFinite && temporalExponent >= 0 && temporalExponent <= 1
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
            let limitation = "compressionExponent 必须满足 0 < spectral alpha ≤ 1，temporalExponent 必须满足 0 ≤ alpha ≤ 1，当前值无效。"
            return PersonalMatchResult(
                matches: references.map { unavailableMatch(reference: $0, limitations: commonLimitations + [limitation]) },
                bestReferenceID: nil,
                modelVersion: resultModelVersion(for: features),
                limitations: commonLimitations + [limitation]
            )
        }
        guard !references.isEmpty else {
            return PersonalMatchResult(
                matches: [],
                bestReferenceID: nil,
                modelVersion: resultModelVersion(for: features),
                limitations: commonLimitations + ["没有提供参考曲线。"]
            )
        }
        guard let headphoneCurve = headphone.curve else {
            let limitation = "缺少耳机实测曲线。"
            return PersonalMatchResult(
                matches: references.map { unavailableMatch(reference: $0, limitations: commonLimitations + [limitation]) },
                bestReferenceID: nil,
                modelVersion: resultModelVersion(for: features),
                limitations: commonLimitations + [limitation]
            )
        }
        guard validFeatureShape(features) else {
            let limitation = "频率网格、显式 cell 边界或逐声道 PSD 形状无效，无法计算。"
            return PersonalMatchResult(
                matches: references.map { unavailableMatch(reference: $0, limitations: commonLimitations + [limitation]) },
                bestReferenceID: nil,
                modelVersion: resultModelVersion(for: features),
                limitations: commonLimitations + [limitation]
            )
        }
        guard let support = commonSupport(
            features: features,
            headphoneCurve: headphoneCurve,
            // A mono recording has no right-channel PSD, so an optional
            // right-channel measurement must not constrain its support.
            rightCurve: features.channelCount > 1 ? headphone.rightCurve : nil,
            eqCurve: headphone.eqCurve,
            references: references
        ) else {
            let limitation = "耳机、所有参考曲线与录音没有共同频段。"
            return PersonalMatchResult(
                matches: references.map { unavailableMatch(reference: $0, limitations: commonLimitations + [limitation]) },
                bestReferenceID: nil,
                modelVersion: resultModelVersion(for: features),
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
        let baselineWeights = makeWeightPlan(
            prepared: prepared,
            spectralExponent: configuration.compressionExponent,
            temporalExponent: configuration.temporalExponent
        )

        // The spectral grid, band overlaps, integrated PSD energies, and
        // headphone interpolation are shared by every reference and every
        // sensitivity scenario. Response observations are computed once per
        // reference; scenarios only reuse those observations with another
        // compact weight plan.
        let responseObservations = references.map { reference in
            let referenceValues = features.frequencyBinsHz.map { reference.value(at: $0) }
            return makeReferenceObservations(
                features: features,
                referenceValues: referenceValues,
                prepared: prepared,
                headphoneValues: prepared.headphoneValues
            )
        }
        let matches = references.indices.map { index in
            evaluate(
                reference: references[index],
                support: support,
                definitions: definitions,
                prepared: prepared,
                observations: responseObservations[index],
                weights: baselineWeights,
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

        let sensitivityDiagnostics = configuration.includeSensitivityDiagnostics
            ? makeSensitivityDiagnostics(
                references: references,
                support: support,
                definitions: definitions,
                prepared: prepared,
                responseObservations: responseObservations,
                rankingUpper: rankingUpper,
                commonLimitations: commonLimitations,
                baselineWeights: baselineWeights
            )
            : []

        return PersonalMatchResult(
            matches: matches,
            bestReferenceID: bestReferenceID,
            modelVersion: resultModelVersion(for: features),
            commonMinimumHz: support.lowerHz,
            commonMaximumHz: support.upperHz,
            limitations: commonLimitations + support.limitations,
            sensitivityDiagnostics: sensitivityDiagnostics
        )
    }

    private struct SensitivityConfiguration {
        let id: String
        let spectralExponent: Double
        let temporalExponent: Double
    }

    private func makeSensitivityDiagnostics(
        references: [Curve],
        support: CommonSupport,
        definitions: [BandDefinition],
        prepared: PreparedBands,
        responseObservations: [[ReferenceBandObservation]],
        rankingUpper: Double,
        commonLimitations: [String],
        baselineWeights: WeightPlan
    ) -> [PersonalSensitivityScenario] {
        let scenarios = sensitivityConfigurations()
        let explanation = "敏感性情景仅表示独立谱内权重与帧活动权重启发式造成的工程情景跨度，不是置信区间、测量不确定度或个人喜欢概率。"

        return scenarios.map { scenario in
            let weights: WeightPlan
            if scenario.spectralExponent == configuration.compressionExponent &&
                scenario.temporalExponent == configuration.temporalExponent {
                weights = baselineWeights
            } else {
                weights = makeWeightPlan(
                    prepared: prepared,
                    spectralExponent: scenario.spectralExponent,
                    temporalExponent: scenario.temporalExponent
                )
            }
            let values = references.indices.map { index in
                let overall = evaluateOverall(
                    observations: responseObservations[index],
                    definitions: definitions,
                    prepared: prepared,
                    weights: weights,
                    rankingUpper: rankingUpper
                )
                return PersonalSensitivityReference(
                    referenceID: references[index].id,
                    referenceName: references[index].name,
                    overallDeviationDB: overall
                )
            }
            let best = values
                .filter { $0.overallDeviationDB?.isFinite == true }
                .min { lhs, rhs in
                    guard let left = lhs.overallDeviationDB, let right = rhs.overallDeviationDB else {
                        return lhs.overallDeviationDB != nil
                    }
                    if left == right { return lhs.referenceID.uuidString < rhs.referenceID.uuidString }
                    return left < right
                }?.referenceID
            let scenarioWeightLimitation = "频谱权重是归一化逐带功率的 \(scenario.spectralExponent) 次压缩启发式；帧活动权重是非零帧能量的 \(scenario.temporalExponent) 次压缩启发式，二者都不是 ISO 响度或听阈模型。"
            var limitations: [String] = []
            for limitation in commonLimitations.filter({ !$0.contains("频谱权重是") }) +
                [scenarioWeightLimitation] + support.limitations + [explanation]
                where !limitations.contains(limitation) {
                limitations.append(limitation)
            }
            return PersonalSensitivityScenario(
                id: scenario.id,
                spectralExponent: scenario.spectralExponent,
                temporalExponent: scenario.temporalExponent,
                references: values,
                bestReferenceID: best,
                limitations: limitations
            )
        }
    }

    private func sensitivityConfigurations() -> [SensitivityConfiguration] {
        let base = SensitivityConfiguration(
            id: "baseline",
            spectralExponent: configuration.compressionExponent,
            temporalExponent: configuration.temporalExponent
        )
        let candidates = [
            base,
            SensitivityConfiguration(id: "spectral-0.2", spectralExponent: 0.2, temporalExponent: configuration.temporalExponent),
            SensitivityConfiguration(id: "spectral-0.5", spectralExponent: 0.5, temporalExponent: configuration.temporalExponent),
            SensitivityConfiguration(id: "temporal-0", spectralExponent: configuration.compressionExponent, temporalExponent: 0),
            SensitivityConfiguration(id: "temporal-1", spectralExponent: configuration.compressionExponent, temporalExponent: 1)
        ]
        var result: [SensitivityConfiguration] = []
        for candidate in candidates where candidate.spectralExponent.isFinite && candidate.temporalExponent.isFinite {
            guard !result.contains(where: {
                $0.spectralExponent == candidate.spectralExponent &&
                    $0.temporalExponent == candidate.temporalExponent
            }) else { continue }
            result.append(candidate)
        }
        return result
    }

    private func evaluateOverall(
        observations: [ReferenceBandObservation],
        definitions: [BandDefinition],
        prepared: PreparedBands,
        weights: WeightPlan,
        rankingUpper: Double
    ) -> Double? {
        let ranking = observations.filter { observation in
            let definition = definitions[observation.base.bandIndex]
            return definition.isRankingBand &&
                definition.lowerHz < rankingUpper &&
                observation.deviationDB != nil
        }
        let usable = ranking.filter { observation in
            observation.base.energy > 0 && observationWeight(observation, in: observations, weights: weights) > 0
        }
        guard prepared.totalMainEnergy > 0 else { return nil }
        let gain = weightedMean(usable.compactMap { observation in
            guard let value = observation.deviationDB else { return nil }
            return (value, observationWeight(observation, in: observations, weights: weights))
        })
        guard gain.isFinite else { return nil }
        return weightedRMS(usable.compactMap { observation in
            guard let value = observation.deviationDB else { return nil }
            return (value - gain, observationWeight(observation, in: observations, weights: weights))
        })
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
    }

    private struct WeightPlan {
        let frameWeights: [Double]
        let spectralWeights: [Double]

        func frameWeight(for observation: BandBaseObservation) -> Double {
            guard observation.frameIndex >= 0 && observation.frameIndex < frameWeights.count else { return 0 }
            return frameWeights[observation.frameIndex]
        }

        func spectralWeight(for index: Int) -> Double {
            guard index >= 0 && index < spectralWeights.count else { return 0 }
            return spectralWeights[index]
        }
    }

    private struct PreparedBands {
        let plans: [BandPlan]
        let observations: [BandBaseObservation]
        let frameMainEnergies: [Double]
        let totalMainEnergy: Double
        let totalAllEnergy: Double
        let headphoneValues: [[Double?]]
    }

    private struct ReferenceBandObservation {
        let index: Int
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
        support: CommonSupport,
        definitions: [BandDefinition],
        prepared: PreparedBands,
        observations: [ReferenceBandObservation],
        weights: WeightPlan,
        rankingUpper: Double,
        commonLimitations: [String]
    ) -> PersonalReferenceMatch {
        let ranking = observations.filter { observation in
            let definition = definitions[observation.base.bandIndex]
            return definition.isRankingBand &&
                definition.lowerHz < rankingUpper &&
                observation.deviationDB != nil
        }
        let usableRanking = ranking.filter { observation in
            let weight = observationWeight(observation, in: observations, weights: weights)
            return observation.base.energy > 0 && weight > 0
        }
        let rankingWeight = usableRanking.reduce(0) { partial, observation in
            partial + observationWeight(observation, in: observations, weights: weights)
        }

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
                    observations: observations,
                    weights: weights,
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
                return (deviationDB, observationWeight(observation, in: observations, weights: weights))
            }
        )
        let overall = weightedRMS(
            usableRanking.compactMap { observation in
                guard let deviationDB = observation.deviationDB else { return nil }
                return (deviationDB - globalGain, observationWeight(observation, in: observations, weights: weights))
            }
        )
        let high = weightedRMS(
            usableRanking.compactMap { observation in
                let definition = definitions[observation.base.bandIndex]
                guard definition.isHighFrequency, let deviationDB = observation.deviationDB else { return nil }
                return (deviationDB - globalGain, observationWeight(observation, in: observations, weights: weights))
            }
        )
        let frameErrors = makeFrameErrors(
            observations: ranking,
            definitions: definitions,
            globalGain: globalGain,
            weights: weights
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
        if observations.contains(where: { $0.base.energy > $0.responseEnergy * 1.000001 }) {
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
                    observations: observations,
                    weights: weights,
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
        let cellEdges = validatedCellEdges(features)
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
                    upper: upper,
                    cellEdges: cellEdges
                )
                return width > 0 ? BinOverlap(index: index, widthHz: width) : nil
            }
            let resolutionWidth: Double
            if cellEdges == nil {
                // Keep the native nil-edges diagnostic unchanged. Compact
                // input below uses its actual variable cell widths.
                resolutionWidth = features.sampleRate / Double(features.parameters.frameLength)
            } else {
                resolutionWidth = overlaps
                    .map { cellWidth(frequencies: frequencies, index: $0.index, cellEdges: cellEdges) }
                    .max() ?? 0
            }
            return BandPlan(
                definition: definition,
                overlaps: overlaps,
                isRankingBand: definition.lowerHz < 20_000 && definition.upperHz > 20,
                resolutionLimited: max(0, min(support.upperHz, definition.upperHz) - max(support.lowerHz, definition.lowerHz)) > 0 &&
                    max(0, min(support.upperHz, definition.upperHz) - max(support.lowerHz, definition.lowerHz)) <
                    resolutionWidth
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
        let observations: [BandBaseObservation] = raw.map { value in
            BandBaseObservation(
                frameIndex: value.frame,
                startTimeSeconds: value.start,
                bandIndex: value.band,
                channelIndex: value.channel,
                energy: value.energy
            )
        }
        return PreparedBands(
            plans: plans,
            observations: observations,
            frameMainEnergies: mainFrameEnergy,
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
        for (observationIndex, base) in prepared.observations.enumerated() {
            let plan = prepared.plans[base.bandIndex]
            var responseEnergy = 0.0
            var responsePower = 0.0
            guard !headphoneValues.isEmpty else {
                result.append(ReferenceBandObservation(index: observationIndex, base: base, deviationDB: nil, responseEnergy: 0))
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
                    index: observationIndex,
                    base: base,
                    deviationDB: deviation,
                    responseEnergy: responseEnergy
                )
            )
        }
        return result
    }

    /// Derives the two independent weighting vectors from the already
    /// integrated band energies. It never rereads PSD or interpolates a
    /// headphone/reference curve, which keeps sensitivity diagnostics cheap.
    private func makeWeightPlan(
        prepared: PreparedBands,
        spectralExponent: Double,
        temporalExponent: Double
    ) -> WeightPlan {
        guard spectralExponent.isFinite, spectralExponent > 0, spectralExponent <= 1,
              temporalExponent.isFinite, temporalExponent >= 0, temporalExponent <= 1 else {
            return WeightPlan(
                frameWeights: Array(repeating: 0, count: prepared.frameMainEnergies.count),
                spectralWeights: Array(repeating: 0, count: prepared.observations.count)
            )
        }

        var spectralNormalizers = Array(repeating: 0.0, count: prepared.frameMainEnergies.count)
        for observation in prepared.observations {
            let plan = prepared.plans[observation.bandIndex]
            let frameEnergy = prepared.frameMainEnergies[observation.frameIndex]
            guard plan.isRankingBand, frameEnergy > 0, observation.energy > 0 else { continue }
            spectralNormalizers[observation.frameIndex] += pow(observation.energy / frameEnergy, spectralExponent)
        }

        let frameWeights = prepared.frameMainEnergies.map { frameEnergy in
            guard prepared.totalMainEnergy > 0, frameEnergy > 0 else { return 0.0 }
            // temporalExponent == 0 deliberately means equal weight for each
            // non-zero frame; zero-energy frames remain excluded.
            return pow(frameEnergy / prepared.totalMainEnergy, temporalExponent)
        }
        let spectralWeights = prepared.observations.map { observation in
            let plan = prepared.plans[observation.bandIndex]
            let frameEnergy = prepared.frameMainEnergies[observation.frameIndex]
            guard frameEnergy > 0, observation.energy > 0 else { return 0.0 }
            let raw = pow(observation.energy / frameEnergy, spectralExponent)
            guard raw.isFinite, raw > 0 else { return 0.0 }
            if plan.isRankingBand {
                let normalizer = spectralNormalizers[observation.frameIndex]
                return normalizer > 0 ? raw / normalizer : 0.0
            }
            // Extended bands may be shown as evidence, but never enter the
            // 20 Hz–20 kHz frame spectral normalizer.
            return raw
        }
        return WeightPlan(frameWeights: frameWeights, spectralWeights: spectralWeights)
    }

    private func observationWeight(
        _ observation: ReferenceBandObservation,
        in allObservations: [ReferenceBandObservation],
        weights: WeightPlan
    ) -> Double {
        guard observation.index >= 0 && observation.index < allObservations.count else { return 0 }
        let base = allObservations[observation.index].base
        return weights.frameWeight(for: base) * weights.spectralWeight(for: observation.index)
    }

    private func makeBandEvidence(
        definitions: [BandDefinition],
        plans: [BandPlan],
        observations: [ReferenceBandObservation],
        weights: WeightPlan,
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
            let bandWeight = bandObservations.reduce(0) {
                $0 + observationWeight($1, in: observations, weights: weights)
            }
            let deviation = globalGain.flatMap { gain in
                weightedRMS(
                    bandObservations.compactMap { observation in
                        guard let value = observation.deviationDB else { return nil }
                        return (value - gain, observationWeight(observation, in: observations, weights: weights))
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
        globalGain: Double,
        weights: WeightPlan
    ) -> [FrameError] {
        let grouped = Dictionary(grouping: observations) { $0.base.frameIndex }
        return grouped.compactMap { _, values in
            let main = values.filter { definitions[$0.base.bandIndex].isRankingBand }
            let error = weightedRMS(
                main.compactMap { observation in
                guard let value = observation.deviationDB else { return nil }
                    return (value - globalGain, weights.spectralWeight(for: observation.index))
                }
            )
            guard let first = values.first, let error else { return nil }
            return FrameError(
                startTimeSeconds: first.base.startTimeSeconds,
                errorDB: error,
                weight: weights.frameWeight(for: first.base)
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
              zip(features.frequencyBinsHz, features.frequencyBinsHz.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              validCellEdges(features) else {
            return false
        }
        return features.frames.allSatisfy { frame in
            frame.powerSpectralDensityByChannel.count == features.channelCount &&
                frame.powerSpectralDensityByChannel.allSatisfy {
                    $0.count == features.frequencyBinsHz.count && $0.allSatisfy { $0.isFinite && $0 >= 0 }
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
        if features.compactStorage != nil {
            result.append(Self.compactApproximationLimitation)
            if features.frequencyValidity == .mathematicalNyquist {
                result.append("频率上限仍只是 PCM 的数学 Nyquist，不证明对应频段含有实测内容")
            }
        }
        result.append("频谱权重是归一化逐带功率的 \(configuration.compressionExponent) 次压缩启发式；帧活动权重是非零帧能量的 \(configuration.temporalExponent) 次压缩启发式，二者都不是 ISO 响度或听阈模型。")
        result.append("最差片段时间表示非零帧的谱形差异，不是可听性判断；帧活动权重也不是心理声学时间积分。")
        return result
    }

    private static let compactApproximationLimitation =
        "compact 频谱按 cell 内 PSD 密度积分后以中心频率近似曲线权重；高 Q 峰、峰位与 20 kHz 边界可能改变，不能视为无损或与原始逐频率结果数学等价"

    private func resultModelVersion(for features: SpectrumFeatures) -> String {
        features.compactStorage == nil
            ? Self.modelVersion
            : Self.modelVersion + "-compact-v1"
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

    private func cellWidth(frequencies: [Double], index: Int, cellEdges: [Double]?) -> Double {
        if let cellEdges {
            let width = cellEdges[index + 1] - cellEdges[index]
            return width.isFinite && width > 0 ? width : 0
        }
        let cellLower = index == frequencies.startIndex
            ? frequencies[index]
            : (frequencies[index - 1] + frequencies[index]) / 2
        let cellUpper = index == frequencies.index(before: frequencies.endIndex)
            ? frequencies[index]
            : (frequencies[index] + frequencies[index + 1]) / 2
        let width = cellUpper - cellLower
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
            cellLower = index == frequencies.startIndex
                ? frequencies[index]
                : (frequencies[index - 1] + frequencies[index]) / 2
            cellUpper = index == frequencies.index(before: frequencies.endIndex)
                ? frequencies[index]
                : (frequencies[index] + frequencies[index + 1]) / 2
        }
        let overlap = min(cellUpper, upper) - max(cellLower, lower)
        return overlap.isFinite && overlap > 0 ? overlap : 0
    }

    private func formatHz(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.4gk", value / 1_000) : String(format: "%.4g", value)
    }
}

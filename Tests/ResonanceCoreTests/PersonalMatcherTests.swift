import XCTest
@testable import ResonanceCore

final class PersonalMatcherTests: XCTestCase {
    private let testFrequencies: [Double] = [0] + Array(stride(from: 20.0, through: 24_000.0, by: 20.0))
    private let curveFrequencies: [Double] = [20, 1_000, 5_000, 10_000, 12_500, 16_000, 20_000, 24_000]

    func testIdentityGlobalLevelAndPCMLevelInvariance() throws {
        let flat = try makeCurve { _ in 0 }
        let headphone = Headphone(name: "flat", owned: true, curve: flat)
        let features = try makeFeatures(frames: [spectrum { 0.1 + ($0 / 24_000) }, spectrum { 0.4 + ($0 / 24_000) }])

        let result = PersonalMatcher().match(features: features, headphone: headphone, references: [flat])
        let match = try XCTUnwrap(result.matches.first)
        XCTAssertEqual(try XCTUnwrap(match.overallDeviationDB), 0, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(match.highFrequencyDeviationDB), 0, accuracy: 1e-8)
        XCTAssertEqual(result.bestReferenceID, flat.id)

        let boosted = try makeCurve { _ in 5 }
        let boostedResult = PersonalMatcher().match(
            features: features,
            headphone: Headphone(name: "boosted", owned: true, curve: boosted),
            references: [flat]
        )
        let boostedMatch = try XCTUnwrap(boostedResult.matches.first)
        XCTAssertEqual(try XCTUnwrap(boostedMatch.overallDeviationDB), 0, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(boostedMatch.globalLevelOffsetDB), 5, accuracy: 1e-8)

        let scaled = try makeFeatures(frames: [
            spectrum(scale: 17) { 0.1 + ($0 / 24_000) },
            spectrum(scale: 17) { 0.4 + ($0 / 24_000) }
        ])
        let scaledMatch = try XCTUnwrap(PersonalMatcher().match(features: scaled, headphone: headphone, references: [flat]).matches.first)
        XCTAssertEqual(try XCTUnwrap(scaledMatch.overallDeviationDB), try XCTUnwrap(match.overallDeviationDB), accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(scaledMatch.highFrequencyDeviationDB), try XCTUnwrap(match.highFrequencyDeviationDB), accuracy: 1e-8)
    }

    func testLowHighShapeAndFrameEvidence() throws {
        let headphoneCurve = try makeCurve { frequency in frequency < 10_000 ? 4 : -4 }
        let reference = try makeCurve { _ in 0 }
        let features = try makeFeatures(frames: [
            spectrum { frequency in frequency < 2_000 ? 4 : 0.01 },
            spectrum { frequency in frequency < 2_000 ? 0.01 : 4 },
            spectrum { frequency in frequency < 2_000 ? 0.2 : 0.2 }
        ])

        let match = try XCTUnwrap(PersonalMatcher().match(
            features: features,
            headphone: Headphone(name: "shape", owned: true, curve: headphoneCurve),
            references: [reference]
        ).matches.first)
        XCTAssertGreaterThan(try XCTUnwrap(match.overallDeviationDB), 0)
        XCTAssertGreaterThan(try XCTUnwrap(match.highFrequencyDeviationDB), 0)
        XCTAssertNotNil(match.frameErrorP90DB)
        XCTAssertNotNil(match.worstFrameErrorDB)
        XCTAssertNotNil(match.worstFrameStartTimeSeconds)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(match.worstFrameErrorDB), try XCTUnwrap(match.frameErrorP90DB))
        XCTAssertTrue(match.frequencyEvidence.contains { $0.isHighFrequency && $0.deviationDB != nil })
    }

    func testEachReferenceIsEvaluatedIndependentlyAndBestDoesNotSplice() throws {
        let headphoneCurve = try makeCurve { frequency in frequency < 10_000 ? 4 : -4 }
        let flatReference = try makeCurve(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) { _ in 0 }
        let matchingReference = try makeCurve(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!) { frequency in frequency < 10_000 ? 4 : -4 }
        let features = try makeFeatures(frames: [spectrum { _ in 1 }])

        let result = PersonalMatcher().match(
            features: features,
            headphone: Headphone(name: "shape", owned: true, curve: headphoneCurve),
            references: [flatReference, matchingReference]
        )
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual(result.bestReferenceID, matchingReference.id)
        XCTAssertGreaterThan(
            try XCTUnwrap(result.matches[0].overallDeviationDB),
            try XCTUnwrap(result.matches[1].overallDeviationDB)
        )
        XCTAssertTrue(result.limitations.contains { $0.contains("未跨参考拼接") })
        XCTAssertTrue(result.matches.allSatisfy { !$0.frequencyEvidence.isEmpty })
    }

    func testSamplingDensityDoesNotChangeBandPowerResultSubstantially() throws {
        let headphoneCurve = try makeCurve { frequency in frequency < 10_000 ? 3 : -2 }
        let reference = try makeCurve { _ in 0 }
        let sparseFrequencies = [0.0, 20, 200, 1_000, 5_000, 10_000, 12_500, 16_000, 20_000, 24_000]
        let sparse = try makeFeatures(frequencies: sparseFrequencies, frames: [sparseFrequencies.map { _ in 1 }])
        let dense = try makeFeatures(frames: [testFrequencies.map { _ in 1 }])
        let sparseResult = try XCTUnwrap(PersonalMatcher().match(
            features: sparse,
            headphone: Headphone(name: "shape", owned: true, curve: headphoneCurve),
            references: [reference]
        ).matches.first?.overallDeviationDB)
        let denseResult = try XCTUnwrap(PersonalMatcher().match(
            features: dense,
            headphone: Headphone(name: "shape", owned: true, curve: headphoneCurve),
            references: [reference]
        ).matches.first?.overallDeviationDB)
        XCTAssertEqual(sparseResult, denseResult, accuracy: 0.75)
    }

    func testSilentPartialRangeAndExtendedFrequencyAreExplicit() throws {
        let flat = try makeCurve { _ in 0 }
        let silent = try makeFeatures(frames: [spectrum(scale: 0) { _ in 1 }])
        let silentResult = PersonalMatcher().match(
            features: silent,
            headphone: Headphone(name: "flat", owned: true, curve: flat),
            references: [flat]
        )
        XCTAssertNil(silentResult.bestReferenceID)
        XCTAssertNil(silentResult.matches.first?.overallDeviationDB)
        XCTAssertTrue(silentResult.matches.first?.frequencyEvidence.contains { $0.state == .noAudioContent } == true)

        let partial = try makeFeatures(
            frames: [spectrum { _ in 1 }],
            coverage: .partial,
            hasUnexplainedGaps: true
        )
        let partialMatch = try XCTUnwrap(PersonalMatcher().match(
            features: partial,
            headphone: Headphone(name: "flat", owned: true, curve: flat),
            references: [flat]
        ).matches.first)
        XCTAssertNotNil(partialMatch.overallDeviationDB)
        XCTAssertEqual(partialMatch.status, .partial)
        XCTAssertTrue(partialMatch.limitations.contains { $0.contains("缺口") })

        let lowRangeFrequencies = Array([0.0] + Array(stride(from: 20.0, through: 10_000.0, by: 20.0)))
        let lowRangeCurve = try makeCurve(frequencies: [20, 1_000, 10_000]) { _ in 0 }
        let lowRange = try makeFeatures(frequencies: lowRangeFrequencies, frames: [lowRangeFrequencies.map { _ in 1 }])
        let lowRangeMatch = try XCTUnwrap(PersonalMatcher().match(
            features: lowRange,
            headphone: Headphone(name: "low", owned: true, curve: lowRangeCurve),
            references: [lowRangeCurve]
        ).matches.first)
        XCTAssertNil(lowRangeMatch.highFrequencyDeviationDB)
        XCTAssertLessThanOrEqual(lowRangeMatch.evaluatedMaxHz ?? .infinity, 10_000)

        let extendedCurve = try makeCurve { _ in 0 }
        let extended = try makeFeatures(frames: [spectrum { _ in 1 }])
        let extendedResult = PersonalMatcher().match(
            features: extended,
            headphone: Headphone(name: "extended", owned: true, curve: extendedCurve),
            references: [extendedCurve]
        )
        XCTAssertGreaterThan(extendedResult.commonMaximumHz ?? 0, 20_000)
        XCTAssertTrue(extendedResult.limitations.contains { $0.contains("扩展频段") })
        XCTAssertTrue(extendedResult.matches.first?.frequencyEvidence.contains { $0.isExtendedFrequency } == true)
        let energyFractionSum = extendedResult.matches.first?.frequencyEvidence
            .compactMap(\.measuredEnergyFraction)
            .reduce(0, +) ?? 0
        XCTAssertEqual(energyFractionSum, 1, accuracy: 1e-8, "band integration must conserve total PSD energy")
    }

    func testCompressionSensitivityAndInvalidConfiguration() throws {
        let headphoneCurve = try makeCurve { frequency in frequency < 10_000 ? 5 : -1 }
        let reference = try makeCurve { _ in 0 }
        let features = try makeFeatures(frames: [
            spectrum { frequency in frequency < 10_000 ? 1 : 0.01 },
            spectrum { frequency in frequency < 10_000 ? 0.01 : 1 }
        ])
        for alpha in [0.2, 0.3, 0.5] {
            let result = PersonalMatcher(configuration: .init(compressionExponent: alpha)).match(
                features: features,
                headphone: Headphone(name: "shape", owned: true, curve: headphoneCurve),
                references: [reference]
            )
            XCTAssertNotNil(result.matches.first?.overallDeviationDB)
            XCTAssertEqual(result.bestReferenceID, reference.id)
        }

        let invalid = PersonalMatcher(configuration: .init(compressionExponent: 0)).match(
            features: features,
            headphone: Headphone(name: "shape", owned: true, curve: headphoneCurve),
            references: [reference]
        )
        XCTAssertNil(invalid.bestReferenceID)
        XCTAssertTrue(invalid.limitations.contains { $0.contains("0 < spectral alpha") })
    }

    func testLegacyAlphaMapsToBothWeightDimensionsAndScenariosAreIndependent() throws {
        let flat = try makeCurve { _ in 0 }
        let headphone = Headphone(name: "flat", owned: true, curve: flat)
        let features = try makeFeatures(frames: [
            spectrum(scale: 0.1) { _ in 1 },
            spectrum(scale: 1.0) { _ in 1 }
        ])

        let legacy = PersonalMatcher.Configuration(compressionExponent: 0.3)
        XCTAssertEqual(legacy.compressionExponent, 0.3, accuracy: 1e-12)
        XCTAssertEqual(legacy.temporalExponent, 0.3, accuracy: 1e-12)
        XCTAssertTrue(legacy.isValid)

        let baseline = PersonalMatcher(configuration: legacy).match(
            features: features,
            headphone: headphone,
            references: [flat]
        )
        XCTAssertEqual(baseline.sensitivityDiagnostics.map(\.id), [
            "baseline", "spectral-0.2", "spectral-0.5", "temporal-0", "temporal-1"
        ])
        XCTAssertEqual(baseline.sensitivityDiagnostics.count, Set(baseline.sensitivityDiagnostics.map(\.id)).count)

        let temporalZero = try XCTUnwrap(baseline.sensitivityDiagnostics.first { $0.id == "temporal-0" })
        let independent = PersonalMatcher(configuration: .init(
            compressionExponent: 0.3,
            temporalExponent: 0,
            includeSensitivityDiagnostics: false
        )).match(features: features, headphone: headphone, references: [flat])
        XCTAssertEqual(
            try XCTUnwrap(temporalZero.references.first?.overallDB),
            try XCTUnwrap(independent.matches.first?.overallDB),
            accuracy: 1e-12
        )
        XCTAssertEqual(temporalZero.bestReferenceID, independent.bestReferenceID)

        let disabled = PersonalMatcher(configuration: .init(
            compressionExponent: 0.3,
            temporalExponent: 0.3,
            includeSensitivityDiagnostics: false
        )).match(features: features, headphone: headphone, references: [flat])
        XCTAssertTrue(disabled.sensitivityDiagnostics.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(disabled.matches.first?.overallDB),
            try XCTUnwrap(baseline.matches.first?.overallDB),
            accuracy: 1e-12
        )
    }

    func testLowEnergyNarrowBandResponseRemainsVisibleInEvidence() throws {
        let reference = try makeCurve { _ in 0 }
        let narrowPeak = try makeCurve(frequencies: [20, 990, 1_000, 1_010, 5_000, 10_000, 12_500, 16_000, 20_000, 24_000]) { frequency in
            abs(frequency - 1_000) < 0.1 ? 6 : 0
        }
        let features = try makeFeatures(frames: [
            spectrum { frequency in abs(frequency - 1_000) < 0.1 ? 0.000001 : 1 }
        ])
        let result = PersonalMatcher().match(
            features: features,
            headphone: Headphone(name: "narrow", owned: true, curve: narrowPeak),
            references: [reference]
        )
        let evidence = try XCTUnwrap(result.matches.first?.frequencyEvidence.first { $0.lowerHz <= 1_000 && $0.upperHz > 1_000 })
        XCTAssertNotNil(evidence.deviationDB)
        XCTAssertNotEqual(evidence.state, .outsideSupport)
    }

    func testMonoPersonalMatchIgnoresUnusedRightCurveButStereoUsesIt() throws {
        let flat = try makeCurve { _ in 0 }
        let narrowRight = try makeCurve(
            frequencies: [1_000, 2_000, 5_000],
            validMinHz: 1_000,
            validMaxHz: 5_000
        ) { _ in 0 }
        let disjointRight = try makeCurve(
            frequencies: [30_000, 35_000, 40_000],
            validMinHz: 30_000,
            validMaxHz: 40_000
        ) { _ in 0 }
        let mono = try makeFeatures(channelCount: 1, frames: [spectrum { _ in 1 }])
        let stereo = try makeFeatures(channelCount: 2, frames: [spectrum { _ in 1 }])
        let leftOnly = Headphone(name: "left-only", owned: true, curve: flat)

        let monoBaseline = PersonalMatcher().match(features: mono, headphone: leftOnly, references: [flat])
        let monoNarrowRight = PersonalMatcher().match(
            features: mono,
            headphone: Headphone(name: "mono-narrow-right", owned: true, curve: flat, rightCurve: narrowRight),
            references: [flat]
        )
        let monoDisjointRight = PersonalMatcher().match(
            features: mono,
            headphone: Headphone(name: "mono-disjoint-right", owned: true, curve: flat, rightCurve: disjointRight),
            references: [flat]
        )
        for result in [monoNarrowRight, monoDisjointRight] {
            XCTAssertEqual(result.bestReferenceID, monoBaseline.bestReferenceID)
            XCTAssertEqual(result.commonMinimumHz, monoBaseline.commonMinimumHz)
            XCTAssertEqual(result.commonMaximumHz, monoBaseline.commonMaximumHz)
            let expected = try XCTUnwrap(monoBaseline.matches.first)
            let actual = try XCTUnwrap(result.matches.first)
            XCTAssertEqual(try XCTUnwrap(actual.overallDB), try XCTUnwrap(expected.overallDB), accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(actual.highDB), try XCTUnwrap(expected.highDB), accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(actual.frameP90DB), try XCTUnwrap(expected.frameP90DB), accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(actual.worstFrameDB), try XCTUnwrap(expected.worstFrameDB), accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(actual.globalLevelOffsetDB), try XCTUnwrap(expected.globalLevelOffsetDB), accuracy: 1e-12)
        }

        let stereoNarrowRight = PersonalMatcher().match(
            features: stereo,
            headphone: Headphone(name: "stereo-narrow-right", owned: true, curve: flat, rightCurve: narrowRight),
            references: [flat]
        )
        XCTAssertEqual(try XCTUnwrap(stereoNarrowRight.commonMinimumHz), 1_000, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stereoNarrowRight.commonMaximumHz), 5_000, accuracy: 1e-12)
        let stereoDisjointRight = PersonalMatcher().match(
            features: stereo,
            headphone: Headphone(name: "stereo-disjoint-right", owned: true, curve: flat, rightCurve: disjointRight),
            references: [flat]
        )
        XCTAssertNil(stereoDisjointRight.bestReferenceID)
        XCTAssertEqual(stereoDisjointRight.matches.first?.status, .unavailable)
    }

    private func makeCurve(
        id: UUID = UUID(),
        frequencies: [Double]? = nil,
        validMinHz: Double? = nil,
        validMaxHz: Double? = nil,
        _ value: (Double) -> Double
    ) throws -> Curve {
        let frequencies = frequencies ?? curveFrequencies
        return try Curve(
            id: id,
            name: "curve",
            points: frequencies.map { try! CurvePoint(frequencyHz: $0, decibels: value($0)) },
            source: "test",
            measurementSystem: "synthetic",
            validMinHz: validMinHz,
            validMaxHz: validMaxHz,
            isReference: true
        )
    }

    private func makeFeatures(
        frequencies: [Double]? = nil,
        frames: [[Double]],
        channelCount: Int = 2,
        coverage: CoverageKind = .complete,
        hasUnexplainedGaps: Bool = false
    ) throws -> SpectrumFeatures {
        let frequencies = frequencies ?? testFrequencies
        let coverage = try Coverage(
            kind: coverage,
            recordedDurationSeconds: Double(frames.count),
            intervals: [try TimeRange(startSeconds: 0, endSeconds: Double(frames.count))],
            hasUnexplainedGaps: hasUnexplainedGaps
        )
        let spectrumFrames = frames.enumerated().map { index, values in
            SpectrumFrame(
                startTimeSeconds: Double(index),
                sampleCount: 1_024,
                powerSpectralDensityByChannel: Array(repeating: values, count: channelCount)
            )
        }
        return SpectrumFeatures(
            sampleRate: 48_000,
            channelCount: channelCount,
            frequencyBinsHz: frequencies,
            frames: spectrumFrames,
            durationSeconds: Double(frames.count),
            coverage: coverage,
            validMinHz: frequencies.first ?? 0,
            validMaxHz: frequencies.last ?? 0,
            frequencyValidity: .mathematicalNyquist,
            format: AudioFormatMetadata(sampleRate: 48_000, channelCount: channelCount),
            parameters: SpectrumAnalysisParameters(frameLength: 1_024, hopLength: 256, frameDurationSeconds: 1 / 48_000)
        )
    }

    private func spectrum(scale: Double = 1, _ value: (Double) -> Double) -> [Double] {
        testFrequencies.map { max(0, value($0) * scale) }
    }
}

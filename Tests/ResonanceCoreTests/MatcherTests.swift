import XCTest
@testable import ResonanceCore

final class MatcherTests: XCTestCase {
    func testIdenticalCurveHasZeroDAndC() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "flat", values: [0, 0, 0])
        let headphone = Headphone(name: "flat", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let features = try makeFeatures(coverage: .complete)

        let result = Matcher().match(features: features, headphone: headphone, reference: reference)
        XCTAssertTrue(result.isEvaluable)
        XCTAssertEqual(try XCTUnwrap(result.d), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.c), 0, accuracy: 1e-12)
        XCTAssertEqual(result.status, .evaluated)
        XCTAssertEqual(result.frequencyBands.count, 30)
    }

    func testGlobalGainIsRemovedFromD() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let boosted = try makeCurve(name: "boosted", values: [5, 5, 5])
        let headphone = Headphone(name: "boosted", owned: true, curve: boosted, referenceID: reference.id)
        let features = try makeFeatures(coverage: .complete)

        let result = Matcher().match(features: features, headphone: headphone, reference: reference)
        XCTAssertEqual(try XCTUnwrap(result.d), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.c), 0, accuracy: 1e-12)
    }

    func testOpposingStereoCurvesAreNotAveragedBeforeClassicMetrics() throws {
        let reference = try makeCurve(name: "stereo reference", values: [0, 0, 0], isReference: true)
        let left = try makeCurve(name: "left +6/0/-6", values: [6, 0, -6])
        let right = try makeCurve(name: "right -6/0/+6", values: [-6, 0, 6])
        let features = try makeStereoFeatures(leftPSD: [1, 1, 1], rightPSD: [0, 0, 0])

        let result = Matcher().match(
            features: features,
            headphone: Headphone(name: "stereo", owned: true, curve: left, rightCurve: right, referenceID: reference.id),
            reference: reference
        )

        XCTAssertGreaterThan(try XCTUnwrap(result.c), 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(result.d), 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(result.dHigh), 1e-6)
    }

    func testIdenticalStereoCurvesPreserveSingleCurveResult() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let curve = try makeCurve(name: "same left and right", values: [3, -1, 4])
        let features = try makeStereoFeatures(leftPSD: [1, 0.5, 2], rightPSD: [0.25, 2, 0.75])

        let fallback = Matcher().match(
            features: features,
            headphone: Headphone(name: "fallback", owned: true, curve: curve, referenceID: reference.id),
            reference: reference
        )
        let stereo = Matcher().match(
            features: features,
            headphone: Headphone(name: "identical stereo", owned: true, curve: curve, rightCurve: curve, referenceID: reference.id),
            reference: reference
        )

        XCTAssertEqual(try XCTUnwrap(stereo.c), try XCTUnwrap(fallback.c), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stereo.d), try XCTUnwrap(fallback.d), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stereo.dHigh), try XCTUnwrap(fallback.dHigh), accuracy: 1e-12)
    }

    func testSingleChannelDoesNotUseUnheardRightCurve() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let left = try makeCurve(name: "left", values: [3, -1, 4])
        let unrelatedRight = try makeCurve(name: "unrelated right", values: [100, 100, 100])
        let features = try makeMonoFeatures(psd: [1, 0.5, 2])

        let fallback = Matcher().match(
            features: features,
            headphone: Headphone(name: "left only", owned: true, curve: left, referenceID: reference.id),
            reference: reference
        )
        let withUnheardRight = Matcher().match(
            features: features,
            headphone: Headphone(name: "left plus unheard right", owned: true, curve: left, rightCurve: unrelatedRight, referenceID: reference.id),
            reference: reference
        )

        XCTAssertEqual(try XCTUnwrap(withUnheardRight.c), try XCTUnwrap(fallback.c), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(withUnheardRight.d), try XCTUnwrap(fallback.d), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(withUnheardRight.dHigh), try XCTUnwrap(fallback.dHigh), accuracy: 1e-12)
    }

    func testStereoAndEQSupportUseTheActualCommonFrequencyRange() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let left = try makeCurve(name: "left", values: [1, 2, 3])
        let right = try makeCurve(
            name: "right measured from 1 kHz",
            values: [1, 2, 3],
            validMinHz: 1_000
        )
        let eq = try makeCurve(
            name: "EQ measured from 1 kHz",
            values: [0, 0, 0],
            validMinHz: 1_000
        )
        let result = Matcher().match(
            features: try makeStereoFeatures(leftPSD: [1, 1, 1], rightPSD: [1, 1, 1]),
            headphone: Headphone(name: "limited support", owned: true, curve: left, rightCurve: right, referenceID: reference.id, eqCurve: eq),
            reference: reference
        )

        XCTAssertTrue(result.isEvaluable)
        XCTAssertEqual(result.evaluatedMinHz, 1_000, accuracy: 1e-12)
    }

    func testSwappingStereoChannelsAndCurvesPreservesClassicMetrics() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let left = try makeCurve(name: "left", values: [6, 0, -2])
        let right = try makeCurve(name: "right", values: [-3, 2, 5])
        let features = try makeStereoFeatures(leftPSD: [1, 0.5, 2], rightPSD: [0.25, 2, 0.75])
        let swappedFeatures = try makeStereoFeatures(leftPSD: [0.25, 2, 0.75], rightPSD: [1, 0.5, 2])

        let result = Matcher().match(
            features: features,
            headphone: Headphone(name: "stereo", owned: true, curve: left, rightCurve: right, referenceID: reference.id),
            reference: reference
        )
        let swapped = Matcher().match(
            features: swappedFeatures,
            headphone: Headphone(name: "swapped stereo", owned: true, curve: right, rightCurve: left, referenceID: reference.id),
            reference: reference
        )

        XCTAssertEqual(try XCTUnwrap(swapped.c), try XCTUnwrap(result.c), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(swapped.d), try XCTUnwrap(result.d), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(swapped.dHigh), try XCTUnwrap(result.dHigh), accuracy: 1e-12)
    }

    func testCurveLevelOffsetsDoNotChangeNormalizedMetricsOrRelativeBandGain() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "headphone", values: [3, -1, 4])
        let shiftedHeadphoneCurve = try makeCurve(name: "headphone +120", values: [123, 119, 124])
        let shiftedReference = try makeCurve(name: "reference +120", values: [120, 120, 120], isReference: true)
        let features = try makeFeatures(coverage: .complete)

        let base = Matcher().match(
            features: features,
            headphone: Headphone(name: "headphone", owned: true, curve: headphoneCurve, referenceID: reference.id),
            reference: reference
        )
        let shiftedHeadphone = Matcher().match(
            features: features,
            headphone: Headphone(name: "headphone +120", owned: true, curve: shiftedHeadphoneCurve, referenceID: reference.id),
            reference: reference
        )
        let shiftedReferenceResult = Matcher().match(
            features: features,
            headphone: Headphone(name: "headphone", owned: true, curve: headphoneCurve, referenceID: shiftedReference.id),
            reference: shiftedReference
        )

        for result in [shiftedHeadphone, shiftedReferenceResult] {
            XCTAssertEqual(try XCTUnwrap(result.c), try XCTUnwrap(base.c), accuracy: 1e-10)
            XCTAssertEqual(try XCTUnwrap(result.d), try XCTUnwrap(base.d), accuracy: 1e-10)
            XCTAssertEqual(try XCTUnwrap(result.dHigh), try XCTUnwrap(base.dHigh), accuracy: 1e-10)
            let baseGain = try XCTUnwrap(base.frequencyBands.first(where: { $0.band.lowerHz == 16_000 })?.relativeGainDB)
            let shiftedGain = try XCTUnwrap(result.frequencyBands.first(where: { $0.band.lowerHz == 16_000 })?.relativeGainDB)
            XCTAssertEqual(shiftedGain, baseGain, accuracy: 1e-10)
        }
    }

    func testMissingReferenceHasNoNumbersAndUnknownCoverageIsPartial() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "headphone", values: [2, 0, -2])
        let headphone = Headphone(name: "headphone", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let missingReference = Matcher().match(features: try makeFeatures(coverage: .complete), headphone: headphone, reference: nil)
        XCTAssertEqual(missingReference.status, .unevaluable)
        XCTAssertEqual(missingReference.unevaluableReason, .missingReference)
        XCTAssertNil(missingReference.c)
        XCTAssertNil(missingReference.d)

        let uncovered = Matcher().match(features: try makeFeatures(coverage: .unknown), headphone: headphone, reference: reference)
        XCTAssertEqual(uncovered.status, .partial)
        XCTAssertNotNil(uncovered.c)
        XCTAssertNotNil(uncovered.d)
        XCTAssertTrue(uncovered.message?.contains("覆盖范围未知") == true)
    }

    func testPartialUnknownAndGappedCoverageUsesRecordedPSDWithoutFillingGaps() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "headphone", values: [0, 0, 0])
        let headphone = Headphone(name: "headphone", owned: true, curve: headphoneCurve, referenceID: reference.id)

        let partial = try makeFeatures(coverage: .partial, recordedDurationSeconds: 1)
        let partialResult = Matcher().match(features: partial, headphone: headphone, reference: reference)
        XCTAssertEqual(partialResult.status, .partial)
        XCTAssertTrue(partial.coverage.isUsable)

        let gaps = try makeFeatures(coverage: .partial, recordedDurationSeconds: 1, hasUnexplainedGaps: true)
        let gapResult = Matcher().match(features: gaps, headphone: headphone, reference: reference)
        XCTAssertEqual(gapResult.status, .partial)
        XCTAssertNotNil(gapResult.d)
        XCTAssertTrue(gapResult.message?.contains("缺口未按静音补入") == true)
        XCTAssertEqual(try XCTUnwrap(gapResult.d), try XCTUnwrap(partialResult.d), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(gapResult.c), try XCTUnwrap(partialResult.c), accuracy: 1e-12)

        let unknown = try makeFeatures(coverage: .unknown, recordedDurationSeconds: nil)
        let unknownResult = Matcher().match(features: unknown, headphone: headphone, reference: reference)
        XCTAssertEqual(unknownResult.status, .partial)
        XCTAssertNotNil(unknownResult.d)
    }

    func testExplicitReferenceIsTheOnlyReferenceIdentityInput() throws {
        let selectedReference = try makeCurve(name: "selected", values: [0, 0, 0], isReference: false)
        let headphoneCurve = try makeCurve(name: "headphone", values: [2, 0, -2])
        let headphone = Headphone(name: "headphone", owned: true, curve: headphoneCurve, referenceID: UUID())

        let result = Matcher().match(
            features: try makeFeatures(coverage: .complete),
            headphone: headphone,
            reference: selectedReference
        )

        XCTAssertTrue(result.isEvaluable)
        XCTAssertNotNil(result.d)
    }

    func testNonFinitePSDIsRejected() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "headphone", values: [0, 0, 0])
        let headphone = Headphone(name: "headphone", owned: true, curve: headphoneCurve, referenceID: reference.id)

        let result = Matcher().match(
            features: try makeFeatures(coverage: .complete, nonfinitePSD: true),
            headphone: headphone,
            reference: reference
        )

        XCTAssertEqual(result.status, .unevaluable)
        XCTAssertEqual(result.unevaluableReason, .invalidInput)
        XCTAssertNil(result.d)
    }

    func testHighFrequencyMetricUsesContentWhenFullRangeAvailable() throws {
        let reference = try makeCurve(name: "reference", frequencies: [20, 10_000, 20_000], values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "high", frequencies: [20, 10_000, 20_000], values: [0, 4, 0])
        let headphone = Headphone(name: "high", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let features = try makeFeatures(coverage: .complete, frequencies: [20, 10_000, 12_000, 16_000, 20_000])

        let result = Matcher().match(features: features, headphone: headphone, reference: reference)
        XCTAssertNotNil(result.dHigh)
        XCTAssertGreaterThan(result.highFrequencyEnergyRatio ?? 0, 1e-4)
    }

    func testHighFrequencyMetricUsesAnyFiniteEnergyAndReportsActualRange() throws {
        let reference = try makeCurve(name: "reference", frequencies: [20, 10_000, 16_000], values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "high", frequencies: [20, 10_000, 16_000], values: [0, 4, 2])
        let headphone = Headphone(name: "high", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let features = try makeFeatures(
            coverage: .complete,
            frequencies: [20, 10_000, 12_000, 16_000],
            highFrequencyEnergy: 1e-8
        )

        let result = Matcher().match(features: features, headphone: headphone, reference: reference)

        XCTAssertNotNil(result.dHigh)
        XCTAssertGreaterThan(result.highFrequencyEnergyRatio ?? 0, 0)
        XCTAssertLessThan(result.highFrequencyEnergyRatio ?? 1, Matcher.Configuration().minimumHighEnergyRatio)
        XCTAssertTrue(result.message?.contains("高频实际计算 10k–16k Hz") == true)
        XCTAssertTrue(result.message?.contains("能量较少") == true)
    }

    func testExtendedEvidenceKeepsNominalBandAndActualUpperBound() throws {
        let reference = try makeCurve(name: "reference", frequencies: [20, 20_000, 40_000], values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "high", frequencies: [20, 20_000, 40_000], values: [0, 0, 2])
        let headphone = Headphone(name: "high", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let features = try makeFeatures(coverage: .complete, frequencies: [20, 10_000, 20_000, 22_000, 24_000])

        let result = Matcher().match(features: features, headphone: headphone, reference: reference)
        XCTAssertEqual(result.frequencyBands.count, 31)
        XCTAssertEqual(result.frequencyBands.last?.band.lowerHz, 20_000)
        XCTAssertEqual(result.frequencyBands.last?.band.upperHz, 25_000)
        XCTAssertEqual(result.frequencyBands.last?.actualUpperHz, 24_000)
        XCTAssertEqual(result.evaluatedMaxHz, 20_000)
    }

    func testBandNarrowerThanFFTBinIsMarkedInsufficientResolution() throws {
        let reference = try makeCurve(name: "reference", values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "flat", values: [0, 0, 0])
        let headphone = Headphone(name: "flat", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let result = Matcher().match(features: try makeFeatures(coverage: .complete), headphone: headphone, reference: reference)

        XCTAssertEqual(result.frequencyBands.first?.state, .insufficientResolution)
    }

    private func makeCurve(
        name: String,
        frequencies: [Double] = [20, 1_000, 20_000],
        values: [Double],
        isReference: Bool = false,
        validMinHz: Double? = nil,
        validMaxHz: Double? = nil
    ) throws -> Curve {
        try Curve(
            name: name,
            points: zip(frequencies, values).map { try! CurvePoint(frequencyHz: $0.0, decibels: $0.1) },
            source: "test",
            measurementSystem: "synthetic",
            validMinHz: validMinHz,
            validMaxHz: validMaxHz,
            isReference: isReference
        )
    }

    private func makeFeatures(
        coverage: CoverageKind,
        frequencies: [Double] = [20, 1_000, 20_000],
        recordedDurationSeconds: Double? = nil,
        hasUnexplainedGaps: Bool = false,
        nonfinitePSD: Bool = false,
        highFrequencyEnergy: Double = 0.2
    ) throws -> SpectrumFeatures {
        let coverageValue = try Coverage(
            kind: coverage,
            recordedDurationSeconds: recordedDurationSeconds,
            intervals: coverage == .unknown || recordedDurationSeconds != nil ? [] : [TimeRange(startSeconds: 0, endSeconds: 1)],
            hasUnexplainedGaps: hasUnexplainedGaps
        )
        let psd = frequencies.enumerated().map { index, frequency in
            if nonfinitePSD && index == 0 { return Double.nan }
            if frequency >= 10_000 { return highFrequencyEnergy }
            return frequency == 1_000 ? 1.0 : 0.2
        }
        let frame = SpectrumFrame(startTimeSeconds: 0, sampleCount: 1_024, powerSpectralDensityByChannel: [psd, psd])
        return SpectrumFeatures(
            sampleRate: 48_000,
            channelCount: 2,
            frequencyBinsHz: frequencies,
            frames: [frame],
            durationSeconds: 1,
            coverage: coverageValue,
            validMinHz: frequencies.first!,
            validMaxHz: frequencies.last!,
            format: AudioFormatMetadata(sampleRate: 48_000, channelCount: 2),
            parameters: SpectrumAnalysisParameters(frameLength: 1_024, hopLength: 256, frameDurationSeconds: 0.02)
        )
    }

    private func makeMonoFeatures(psd: [Double]) throws -> SpectrumFeatures {
        try makeChannelFeatures(channels: [psd])
    }

    private func makeStereoFeatures(leftPSD: [Double], rightPSD: [Double]) throws -> SpectrumFeatures {
        try makeChannelFeatures(channels: [leftPSD, rightPSD])
    }

    private func makeChannelFeatures(channels: [[Double]]) throws -> SpectrumFeatures {
        let frequencies = [20.0, 1_000, 20_000]
        let coverage = try Coverage(
            kind: .complete,
            intervals: [TimeRange(startSeconds: 0, endSeconds: 1)],
            identityConfirmed: true
        )
        return SpectrumFeatures(
            sampleRate: 48_000,
            channelCount: channels.count,
            frequencyBinsHz: frequencies,
            frames: [SpectrumFrame(
                startTimeSeconds: 0,
                sampleCount: 1_024,
                powerSpectralDensityByChannel: channels
            )],
            durationSeconds: 1,
            coverage: coverage,
            validMinHz: frequencies.first!,
            validMaxHz: frequencies.last!,
            frequencyValidity: .measuredContent,
            format: AudioFormatMetadata(sampleRate: 48_000, channelCount: channels.count),
            parameters: SpectrumAnalysisParameters(frameLength: 1_024, hopLength: 256, frameDurationSeconds: 0.02)
        )
    }
}

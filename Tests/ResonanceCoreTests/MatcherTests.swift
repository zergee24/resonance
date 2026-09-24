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

    func testHighFrequencyMetricRequiresContentAndFullCoverage() throws {
        let reference = try makeCurve(name: "reference", frequencies: [20, 10_000, 20_000], values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "high", frequencies: [20, 10_000, 20_000], values: [0, 4, 0])
        let headphone = Headphone(name: "high", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let features = try makeFeatures(coverage: .complete, frequencies: [20, 10_000, 12_000, 16_000, 20_000])

        let result = Matcher().match(features: features, headphone: headphone, reference: reference)
        XCTAssertNotNil(result.dHigh)
        XCTAssertGreaterThan(result.highFrequencyEnergyRatio ?? 0, 1e-4)
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
        isReference: Bool = false
    ) throws -> Curve {
        try Curve(
            name: name,
            points: zip(frequencies, values).map { try! CurvePoint(frequencyHz: $0.0, decibels: $0.1) },
            source: "test",
            measurementSystem: "synthetic",
            isReference: isReference
        )
    }

    private func makeFeatures(
        coverage: CoverageKind,
        frequencies: [Double] = [20, 1_000, 20_000],
        recordedDurationSeconds: Double? = nil,
        hasUnexplainedGaps: Bool = false,
        nonfinitePSD: Bool = false
    ) throws -> SpectrumFeatures {
        let coverageValue = try Coverage(
            kind: coverage,
            recordedDurationSeconds: recordedDurationSeconds,
            intervals: coverage == .unknown || recordedDurationSeconds != nil ? [] : [TimeRange(startSeconds: 0, endSeconds: 1)],
            hasUnexplainedGaps: hasUnexplainedGaps
        )
        let psd = frequencies.enumerated().map { index, frequency in
            if nonfinitePSD && index == 0 { return Double.nan }
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
}

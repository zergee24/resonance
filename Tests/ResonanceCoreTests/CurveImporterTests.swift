import XCTest
@testable import ResonanceCore

final class CurveImporterTests: XCTestCase {
    private let importer = CurveImporter()

    func testParsesHeadersCommentsAndInterpolatesOnLogFrequency() throws {
        let curve = try importer.parse(
            text: "# Hz,dB\nfrequency,level\n100,0\n1000,10\n10000,20\n",
            name: "sample",
            source: "test",
            measurementSystem: "fixture"
        )

        XCTAssertEqual(curve.points.count, 3)
        XCTAssertEqual(try XCTUnwrap(curve.value(at: 100)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(curve.value(at: 1_000)), 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(curve.value(at: 100)), 0, accuracy: 1e-12)
        XCTAssertEqual(curve.value(at: 316.2277660168)!, 5, accuracy: 1e-8)
        XCTAssertNil(curve.value(at: 99.9))
        XCTAssertNil(curve.value(at: 20_000))
    }

    func testAllowsExactDuplicateButRejectsConflictingDuplicate() throws {
        let exact = try importer.parse(
            text: "100,1\n100,1\n1000,2\n",
            name: "sample",
            source: "test",
            measurementSystem: "fixture"
        )
        XCTAssertEqual(exact.points.count, 2)

        XCTAssertThrowsError(try importer.parse(
            text: "100,1\n100,2\n1000,2\n",
            name: "sample",
            source: "test",
            measurementSystem: "fixture"
        )) { error in
            guard case ResonanceCoreError.conflictingDuplicateFrequency = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsNonFiniteValuesAfterHeader() {
        XCTAssertThrowsError(try importer.parse(
            text: "Hz,dB\n100,NaN\n1000,2\n",
            name: "sample",
            source: "test",
            measurementSystem: "fixture"
        )) { error in
            guard case ResonanceCoreError.nonFiniteCurveValue = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExpandedBandsKeepNominalUpperBound() {
        let bands = FrequencyBand.expanded(through: 24_000)
        XCTAssertEqual(bands.count, 31)
        XCTAssertEqual(bands.last?.lowerHz, 20_000)
        XCTAssertEqual(bands.last?.upperHz, 25_000)
    }

    func testAudioToolsMetadataAfterDataIsIgnoredWithoutHidingBadRows() throws {
        let text = """
        FFT\tAudioTools v18.11
        Frequency\tdB\tUnweighted
        19.5\t115.1
        20.0\t115.1
        overall dB\t136.2 dB
        decay\tAverage
        averaging\t1/24 Octave
        source\tHeadset Microphone 1 Low Range
        """
        let curve = try importer.parse(text: text, name: "Raphael", source: "test", measurementSystem: "unknown")
        XCTAssertEqual(curve.points.count, 2)
        XCTAssertEqual(curve.validMinHz, 19.5, accuracy: 1e-12)
        XCTAssertEqual(curve.validMaxHz, 20, accuracy: 1e-12)

        XCTAssertThrowsError(try importer.parse(
            text: "Frequency dB\n19.5 115.1\n20.0 not-a-number\noverall dB 136.2 dB\n",
            name: "damaged",
            source: "test",
            measurementSystem: "unknown"
        ))
    }
}

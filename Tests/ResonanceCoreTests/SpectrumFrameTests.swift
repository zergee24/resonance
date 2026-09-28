import Foundation
import XCTest
@testable import ResonanceCore

final class SpectrumFrameTests: XCTestCase {
    func testDecodesLegacyPropertyListArrayRepresentation() throws {
        let legacy = LegacySpectrumFramePayload(
            startTimeSeconds: 12.5,
            sampleCount: 1_024,
            powerSpectralDensityByChannel: [[0, 1.25, 2.5], [0, -0.5, 4.0]]
        )
        let data = try propertyListEncoder.encode(legacy)

        let decoded = try propertyListDecoder.decode(SpectrumFrame.self, from: data)

        XCTAssertEqual(decoded.startTimeSeconds, legacy.startTimeSeconds)
        XCTAssertEqual(decoded.sampleCount, legacy.sampleCount)
        XCTAssertEqual(decoded.powerSpectralDensityByChannel, legacy.powerSpectralDensityByChannel)
    }

    func testBinaryRoundTripPreservesMultiChannelDoubleBitPatterns() throws {
        let values: [[Double]] = [
            [
                Double(bitPattern: 0x0000_0000_0000_0000),
                Double(bitPattern: 0x8000_0000_0000_0000),
                Double(bitPattern: 0x0000_0000_0000_0001),
                Double(bitPattern: 0x3ff0_0000_0000_0000),
                Double(bitPattern: 0x7ff8_0000_0000_0042)
            ],
            [],
            [
                Double(bitPattern: 0x7ff0_0000_0000_0000),
                Double(bitPattern: 0xffef_ffff_ffff_ffff),
                Double(bitPattern: 0x4014_0000_0000_0000)
            ]
        ]
        let frame = SpectrumFrame(startTimeSeconds: 3.25, sampleCount: 2_048, powerSpectralDensityByChannel: values)

        let data = try propertyListEncoder.encode(frame)
        let decoded = try propertyListDecoder.decode(SpectrumFrame.self, from: data)

        XCTAssertEqual(decoded.startTimeSeconds, frame.startTimeSeconds)
        XCTAssertEqual(decoded.sampleCount, frame.sampleCount)
        XCTAssertEqual(decoded.powerSpectralDensityByChannel.count, values.count)
        for (decodedChannel, expectedChannel) in zip(decoded.powerSpectralDensityByChannel, values) {
            XCTAssertEqual(decodedChannel.map(\.bitPattern), expectedChannel.map(\.bitPattern))
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        )
        XCTAssertNotNil(propertyList["powerSpectralDensityByChannelFloat64LE"] as? [Data])
        XCTAssertNil(propertyList["powerSpectralDensityByChannel"])
    }

    func testRejectsBinaryChannelWithInvalidByteLength() throws {
        let corrupted = BinarySpectrumFramePayload(
            startTimeSeconds: 0,
            sampleCount: 1,
            powerSpectralDensityByChannelFloat64LE: [Data([0x01, 0x02, 0x03])]
        )
        let data = try propertyListEncoder.encode(corrupted)

        XCTAssertThrowsError(try propertyListDecoder.decode(SpectrumFrame.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected DecodingError.dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("not divisible"))
        }
    }

    func testBinaryEncodingIsSmallerForRepresentativePSD() throws {
        let channel = (0..<512).map { index in
            sin(Double(index) / 17.0) * 0.25 + Double(index % 11) * 1e-6
        }
        let frame = SpectrumFrame(
            startTimeSeconds: 1,
            sampleCount: 1_024,
            powerSpectralDensityByChannel: [channel, channel.map { -$0 }, Array(repeating: 0, count: channel.count)]
        )
        let legacy = LegacySpectrumFramePayload(
            startTimeSeconds: frame.startTimeSeconds,
            sampleCount: frame.sampleCount,
            powerSpectralDensityByChannel: frame.powerSpectralDensityByChannel
        )

        let newData = try propertyListEncoder.encode(frame)
        let oldData = try propertyListEncoder.encode(legacy)
        XCTAssertLessThan(newData.count, oldData.count)
    }

    private var propertyListEncoder: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }

    private var propertyListDecoder: PropertyListDecoder { PropertyListDecoder() }
}

private struct LegacySpectrumFramePayload: Codable {
    let startTimeSeconds: Double
    let sampleCount: Int
    let powerSpectralDensityByChannel: [[Double]]
}

private struct BinarySpectrumFramePayload: Codable {
    let startTimeSeconds: Double
    let sampleCount: Int
    let powerSpectralDensityByChannelFloat64LE: [Data]
}

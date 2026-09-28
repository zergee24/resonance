import Foundation

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
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

@main
private struct SpectrumStorageVerification {
    static func main() throws {
        let frame = SpectrumFrame(
            startTimeSeconds: 3.25,
            sampleCount: 2_048,
            powerSpectralDensityByChannel: [
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
        )

        let newData = try encodePropertyList(frame)
        let decoded = try decodePropertyList(SpectrumFrame.self, from: newData)
        try check(decoded.startTimeSeconds == frame.startTimeSeconds, "start time changed in binary round trip")
        try check(decoded.sampleCount == frame.sampleCount, "sample count changed in binary round trip")
        try check(decoded.powerSpectralDensityByChannel.map { $0.map(\.bitPattern) } == frame.powerSpectralDensityByChannel.map { $0.map(\.bitPattern) }, "Float64 bit patterns changed in binary round trip")

        var format = PropertyListSerialization.PropertyListFormat.binary
        let propertyList = try checkValue(
            PropertyListSerialization.propertyList(from: newData, options: [], format: &format) as? [String: Any],
            "new payload is not a keyed property list"
        )
        let encodedChannels = try checkValue(
            propertyList["powerSpectralDensityByChannelFloat64LE"] as? [Data],
            "new binary key is missing"
        )
        try check(
            Data(encodedChannels[0].dropFirst(3 * MemoryLayout<UInt64>.stride).prefix(MemoryLayout<UInt64>.stride)) == Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f]),
            "known 1.0 Float64 byte order is not little-endian"
        )
        try check(propertyList["powerSpectralDensityByChannel"] == nil, "new payload still contains the legacy array key")

        let legacy = LegacySpectrumFramePayload(
            startTimeSeconds: 12.5,
            sampleCount: 1_024,
            powerSpectralDensityByChannel: [[0, 1.25, 2.5], [0, -0.5, 4.0]]
        )
        let legacyData = try encodePropertyList(legacy)
        let legacyDecoded = try decodePropertyList(SpectrumFrame.self, from: legacyData)
        try check(legacyDecoded.powerSpectralDensityByChannel == legacy.powerSpectralDensityByChannel, "legacy array payload did not decode")

        let corrupted = BinarySpectrumFramePayload(
            startTimeSeconds: 0,
            sampleCount: 1,
            powerSpectralDensityByChannelFloat64LE: [Data([0x01, 0x02, 0x03])]
        )
        do {
            _ = try decodePropertyList(SpectrumFrame.self, from: encodePropertyList(corrupted))
            throw VerificationError.failed("corrupted Float64 byte length was accepted")
        } catch DecodingError.dataCorrupted {
            // Expected: a partial Float64 must never be silently padded or truncated.
        }

        let representativeChannel = (0..<512).map { index in
            sin(Double(index) / 17.0) * 0.25 + Double(index % 11) * 1e-6
        }
        let representative = SpectrumFrame(
            startTimeSeconds: 1,
            sampleCount: 1_024,
            powerSpectralDensityByChannel: [representativeChannel, representativeChannel.map { -$0 }, Array(repeating: 0, count: representativeChannel.count)]
        )
        let representativeNewData = try encodePropertyList(representative)
        let representativeLegacyData = try encodePropertyList(LegacySpectrumFramePayload(
            startTimeSeconds: representative.startTimeSeconds,
            sampleCount: representative.sampleCount,
            powerSpectralDensityByChannel: representative.powerSpectralDensityByChannel
        ))
        try check(representativeNewData.count < representativeLegacyData.count, "binary payload is not smaller for representative PSD")

        print("PASS legacy decode, binary round trip, exact Float64 bit patterns, multi-channel/zero values, and corrupt-length rejection")
        print("representative plist bytes: legacy=\(representativeLegacyData.count), binary=\(representativeNewData.count)")
    }

    private static func encodePropertyList<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private static func decodePropertyList<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError.failed(message) }
    }

    private static func checkValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw VerificationError.failed(message) }
        return value
    }
}

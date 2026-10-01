import Foundation

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

private struct LegacyNumericFramePayload: Codable {
    let startTimeSeconds: Double
    let sampleCount: Int
    let powerSpectralDensityByChannel: [[Double]]
}

private struct LegacyFloat64FramePayload: Codable {
    let startTimeSeconds: Double
    let sampleCount: Int
    let powerSpectralDensityByChannelFloat64LE: [Data]
}

private struct RawCompactChannel: Encodable {
    let count: Int
    let baseDB: Double?
    let packedUInt16LE: Data?
    let fallbackFloat64LE: Data?
}

private struct RawCompactFrame: Encodable {
    let startTimeSeconds: Double
    let sampleCount: Int
    let compactEncodingVersion: Int
    let compactStepDB: Double
    let compactChannelCount: Int
    let compactChannels: [RawCompactChannel]
}

@main
private struct CompactCodecVerification {
    static func main() throws {
        try verifyDefaultFloat64EncodingAndLegacyDecoding()
        try verifyPackedQuantization()
        try verifyZeroAndSubnormalValues()
        try verifyDynamicRangeFallback()
        try verifyCorruptMetadata()

        print("PASS legacy numeric/Float64LE bit preservation, compact dB error, zero/subnormal values, dynamic-range fallback, and corrupt metadata rejection")
    }

    private static func verifyDefaultFloat64EncodingAndLegacyDecoding() throws {
        let frame = SpectrumFrame(
            startTimeSeconds: Double(bitPattern: 0x400A_0000_0000_0000),
            sampleCount: 2_048,
            powerSpectralDensityByChannel: [
                [
                    Double(bitPattern: 0x0000_0000_0000_0000),
                    Double(bitPattern: 0x8000_0000_0000_0000),
                    Double(bitPattern: 0x0000_0000_0000_0001),
                    Double(bitPattern: 0x3FF0_0000_0000_0000),
                    Double(bitPattern: 0x7FF8_0000_0000_0042)
                ],
                []
            ]
        )

        let data = try encodePropertyList(frame)
        let dictionary = try propertyListDictionary(data)
        try check(dictionary["powerSpectralDensityByChannel"] == nil, "default encoding still contains the numeric array")
        try check(dictionary["compactChannels"] == nil, "default encoding unexpectedly enabled compact storage")
        let encodedChannels = try checkValue(
            dictionary["powerSpectralDensityByChannelFloat64LE"] as? [Data],
            "default Float64LE key is missing"
        )
        try check(
            bitPatterns(try decodePropertyList(SpectrumFrame.self, from: data).powerSpectralDensityByChannel)
                == bitPatterns(frame.powerSpectralDensityByChannel),
            "default Float64LE round trip changed bit patterns"
        )
        try check(encodedChannels.count == 2, "default Float64LE channel count changed")

        let numeric = LegacyNumericFramePayload(
            startTimeSeconds: 12.5,
            sampleCount: 1_024,
            powerSpectralDensityByChannel: [[0, 1.25, 2.5], [0, 4.0]]
        )
        let numericDecoded = try decodePropertyList(SpectrumFrame.self, from: encodePropertyList(numeric))
        try check(
            bitPatterns(numericDecoded.powerSpectralDensityByChannel) == bitPatterns(numeric.powerSpectralDensityByChannel),
            "legacy numeric array did not decode bit-for-bit"
        )

        let float64Values = [
            Double(bitPattern: 0x0000_0000_0000_0000),
            Double(bitPattern: 0x8000_0000_0000_0000),
            Double(bitPattern: 0x0000_0000_0000_0001),
            Double(bitPattern: 0x7FF0_0000_0000_0000),
            Double(bitPattern: 0x7FF8_0000_0000_0042)
        ]
        let float64Payload = LegacyFloat64FramePayload(
            startTimeSeconds: 1,
            sampleCount: 1,
            powerSpectralDensityByChannelFloat64LE: [float64LE(float64Values)]
        )
        let float64Decoded = try decodePropertyList(SpectrumFrame.self, from: encodePropertyList(float64Payload))
        try check(
            bitPatterns(float64Decoded.powerSpectralDensityByChannel) == bitPatterns([float64Values]),
            "legacy Float64LE payload did not decode bit-for-bit"
        )
    }

    private static func verifyPackedQuantization() throws {
        let values = [1.0, 0.5, 0.125, 1e-12, 0.0, 0.75]
        let frame = SpectrumFrame(startTimeSeconds: 3.25, sampleCount: 512, powerSpectralDensityByChannel: [values])
        let data = try encodePropertyList(frame, compact: true)
        let dictionary = try propertyListDictionary(data)
        try check((dictionary["compactEncodingVersion"] as? NSNumber)?.intValue == 1, "compact encoding version is missing")
        try check((dictionary["compactStepDB"] as? NSNumber)?.doubleValue == 0.01, "compact step metadata is missing")
        try check((dictionary["compactChannelCount"] as? NSNumber)?.intValue == 1, "compact channel count is missing")
        let channel = try compactChannel(dictionary, at: 0)
        try check(channel["packedUInt16LE"] is Data, "valid channel did not use packed UInt16 storage")
        try check(channel["fallbackFloat64LE"] == nil, "valid channel unexpectedly used Float64 fallback")

        let decoded = try decodePropertyList(SpectrumFrame.self, from: data)
        try check(decoded.startTimeSeconds == frame.startTimeSeconds, "compact start time changed")
        try check(decoded.sampleCount == frame.sampleCount, "compact sample count changed")
        try checkQuantizedPSD(values, decoded.powerSpectralDensityByChannel[0])
    }

    private static func verifyZeroAndSubnormalValues() throws {
        let smallest = Double.leastNonzeroMagnitude
        let values = [0.0, -0.0, smallest, smallest * 2]
        let frame = SpectrumFrame(startTimeSeconds: 0.25, sampleCount: 4, powerSpectralDensityByChannel: [values])
        let decoded = try decodePropertyList(
            SpectrumFrame.self,
            from: encodePropertyList(frame, compact: true)
        )
        let decodedValues = try checkValue(decoded.powerSpectralDensityByChannel.first, "subnormal channel is missing")
        try check(decodedValues[0] == 0 && decodedValues[1] == 0, "compact zero code did not decode as zero")
        try check(decodedValues[2] > 0 && decodedValues[3] > 0, "compact subnormal value underflowed to zero")
        try checkQuantizedPSD(values, decodedValues)
    }

    private static func verifyDynamicRangeFallback() throws {
        let values = [1.0, 1e-100, 0.0]
        let frame = SpectrumFrame(startTimeSeconds: 2, sampleCount: 3, powerSpectralDensityByChannel: [values])
        let data = try encodePropertyList(frame, compact: true)
        let channel = try compactChannel(try propertyListDictionary(data), at: 0)
        try check(channel["packedUInt16LE"] == nil, "out-of-range dynamic channel was silently packed")
        try check(channel["fallbackFloat64LE"] is Data, "out-of-range dynamic channel lacks Float64 fallback")

        let decoded = try decodePropertyList(SpectrumFrame.self, from: data)
        try check(
            bitPatterns(decoded.powerSpectralDensityByChannel) == bitPatterns([values]),
            "Float64 fallback did not preserve dynamic-range values"
        )
    }

    private static func verifyCorruptMetadata() throws {
        let malformedLength = RawCompactFrame(
            startTimeSeconds: 0,
            sampleCount: 1,
            compactEncodingVersion: 1,
            compactStepDB: 0.01,
            compactChannelCount: 1,
            compactChannels: [RawCompactChannel(count: 2, baseDB: 0, packedUInt16LE: Data([0]), fallbackFloat64LE: nil)]
        )
        try expectDataCorrupted(
            malformedLength,
            message: "malformed packed length was accepted"
        )

        let unsupportedVersion = RawCompactFrame(
            startTimeSeconds: 0,
            sampleCount: 1,
            compactEncodingVersion: 99,
            compactStepDB: 0.01,
            compactChannelCount: 0,
            compactChannels: []
        )
        try expectDataCorrupted(
            unsupportedVersion,
            message: "unsupported compact version was accepted"
        )

        let invalidStep = RawCompactFrame(
            startTimeSeconds: 0,
            sampleCount: 1,
            compactEncodingVersion: 1,
            compactStepDB: 0.02,
            compactChannelCount: 0,
            compactChannels: []
        )
        try expectDataCorrupted(invalidStep, message: "invalid compact step was accepted")

        let missingBase = RawCompactFrame(
            startTimeSeconds: 0,
            sampleCount: 1,
            compactEncodingVersion: 1,
            compactStepDB: 0.01,
            compactChannelCount: 1,
            compactChannels: [RawCompactChannel(count: 0, baseDB: nil, packedUInt16LE: Data(), fallbackFloat64LE: nil)]
        )
        try expectDataCorrupted(missingBase, message: "packed channel without base dB was accepted")
    }

    private static func tryEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private static func encodePropertyList<T: Encodable>(_ value: T, compact: Bool = false) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if compact {
            encoder.userInfo[CodingUserInfoKey.resonanceCompactSpectrum] = true
        }
        return try encoder.encode(value)
    }

    private static func decodePropertyList<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }

    private static func propertyListDictionary(_ data: Data) throws -> [String: Any] {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw VerificationError.failed("encoded payload is not a keyed property list")
        }
        return dictionary
    }

    private static func compactChannel(_ dictionary: [String: Any], at index: Int) throws -> [String: Any] {
        guard let channels = dictionary["compactChannels"] as? [Any],
              index >= 0,
              index < channels.count,
              let channel = channels[index] as? [String: Any] else {
            throw VerificationError.failed("compact channel metadata is missing")
        }
        return channel
    }

    private static func float64LE(_ values: [Double]) -> Data {
        var data = Data()
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private static func bitPatterns(_ channels: [[Double]]) -> [[UInt64]] {
        channels.map { $0.map(\.bitPattern) }
    }

    private static func checkQuantizedPSD(_ original: [Double], _ decoded: [Double]) throws {
        try check(original.count == decoded.count, "compact channel count changed")
        for (index, pair) in zip(original, decoded).enumerated() {
            if pair.0 == 0 {
                try check(pair.1 == 0, "compact zero at index \(index) changed")
                continue
            }
            let originalDB = 10.0 * log10(pair.0)
            let decodedDB = 10.0 * log10(pair.1)
            try check(
                abs(decodedDB - originalDB) <= 0.005 + 1e-10,
                "compact dB error at index \(index) exceeds 0.005 dB"
            )
        }
    }

    private static func expectDataCorrupted<T: Encodable>(_ value: T, message: String) throws {
        do {
            _ = try decodePropertyList(SpectrumFrame.self, from: try tryEncode(value))
            throw VerificationError.failed(message)
        } catch DecodingError.dataCorrupted {
            return
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError.failed(message) }
    }

    private static func checkValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw VerificationError.failed(message) }
        return value
    }
}

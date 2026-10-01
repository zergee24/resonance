import AVFoundation
import Darwin
import Foundation

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

@main
private struct StreamingAnalysisVerification {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--memory-only" {
            try runMemoryProbe()
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-streaming-analysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try verifyFrameBoundaries(directory: directory)
        try verifyChunkBoundary(directory: directory)
        try verifyMultipleRatesAndChannels(directory: directory)
        try verifyNonFiniteTail(directory: directory)
        print("PASS streaming analysis: bounded file windows preserve samples-path PSD and metadata")
    }

    private static func runMemoryProbe() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-streaming-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sampleRate = 48_000.0
        let sampleCount = Int(sampleRate * 60.0)
        let channels = 2
        let url = directory.appendingPathComponent("synthetic-60s.caf")
        try autoreleasepool {
            try writeLongCAF(sampleCount: sampleCount, sampleRate: sampleRate, channelCount: channels, to: url)
        }

        let before = residentBytes()
        let started = Date()
        let features = try autoreleasepool {
            try SpectrumAnalyzer().analyze(fileURL: url, coverage: .unknown, recordingID: UUID())
        }
        let analysisSeconds = Date().timeIntervalSince(started)
        let after = residentBytes()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let checksum = psdChecksum(features)
        let report: [String: Any] = [
            "sampleRate": sampleRate,
            "seconds": 60,
            "channels": channels,
            "frames": features.frames.count,
            "bins": features.frequencyBinsHz.count,
            "residentBefore": before,
            "residentAfter": after,
            "peakResident": usage.ru_maxrss,
            "analysisSeconds": analysisSeconds,
            "psdChecksum": String(checksum, radix: 16),
            "status": "PASS memory probe; PSD remains fully materialized"
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static func psdChecksum(_ features: SpectrumFeatures) -> UInt64 {
        var checksum: UInt64 = 0
        for frame in features.frames {
            for channel in frame.powerSpectralDensityByChannel {
                for value in channel {
                    checksum = checksum &* 1_099_511_628_211 &+ value.bitPattern
                }
            }
        }
        return checksum
    }

    private static func writeLongCAF(
        sampleCount: Int,
        sampleRate: Double,
        channelCount: Int,
        to url: URL
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else { throw VerificationError.failed("could not create memory probe format") }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let blockCapacity = 65_536
        var offset = 0
        while offset < sampleCount {
            let count = min(blockCapacity, sampleCount - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channelData = buffer.floatChannelData else {
                throw VerificationError.failed("could not allocate memory probe buffer")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channelCount {
                for frame in 0..<count {
                    let absolute = offset + frame
                    let time = Double(absolute) / sampleRate
                    channelData[channel][frame] = Float(
                        0.2 * sin(2.0 * Double.pi * (220.0 + Double(channel) * 110.0) * time)
                        + 0.03 * cos(2.0 * Double.pi * 73.0 * time)
                    )
                }
            }
            try file.write(from: buffer)
            offset += count
        }
    }

    private static func verifyFrameBoundaries(directory: URL) throws {
        let sampleRate = 48_000.0
        let frameLength = 8_192
        let analyzer = SpectrumAnalyzer(configuration: .init(
            frameDurationSeconds: Double(frameLength) / sampleRate,
            hopFraction: 0.25,
            minimumFrameLength: frameLength,
            maximumFrameLength: frameLength
        ))

        for count in [8_191, 8_192, 8_193] {
            let channels = syntheticChannels(count: count, channelCount: 2, sampleRate: sampleRate)
            let url = directory.appendingPathComponent("boundary-\(count).caf")
            try writeCAF(channels: channels, sampleRate: sampleRate, to: url)
            let expectedError = count < frameLength
            try compareFileAndSamples(
                analyzer: analyzer,
                channels: channels,
                sampleRate: sampleRate,
                url: url,
                expectNoFrames: expectedError
            )
        }
        print("PASS frame boundaries: 8191/8192/8193 samples and hop tails")
    }

    private static func verifyChunkBoundary(directory: URL) throws {
        let sampleRate = 48_000.0
        let frameLength = 1_024
        let count = 65_536 + 2_048 + 17
        let channels = syntheticChannels(count: count, channelCount: 2, sampleRate: sampleRate)
        let analyzer = SpectrumAnalyzer(configuration: .init(
            frameDurationSeconds: Double(frameLength) / sampleRate,
            hopFraction: 0.25,
            minimumFrameLength: frameLength,
            maximumFrameLength: frameLength
        ))
        let url = directory.appendingPathComponent("chunk-boundary.caf")
        try writeCAF(channels: channels, sampleRate: sampleRate, to: url)
        try compareFileAndSamples(analyzer: analyzer, channels: channels, sampleRate: sampleRate, url: url)
        print("PASS 65,536-frame decoder boundary and tail")
    }

    private static func verifyMultipleRatesAndChannels(directory: URL) throws {
        for (sampleRate, count) in [(44_100.0, 44_100 * 2 + 333), (48_000.0, 48_000 * 2 + 517)] {
            let channels = syntheticChannels(count: count, channelCount: 2, sampleRate: sampleRate)
            let analyzer = SpectrumAnalyzer(configuration: .init(
                frameDurationSeconds: 1.0 / 32.0,
                hopFraction: 0.25,
                minimumFrameLength: 256,
                maximumFrameLength: 2_048
            ))
            let tag = String(format: "%.0f", sampleRate)
            let url = directory.appendingPathComponent("rate-\(tag).caf")
            try writeCAF(channels: channels, sampleRate: sampleRate, to: url)
            try compareFileAndSamples(analyzer: analyzer, channels: channels, sampleRate: sampleRate, url: url)
        }
        print("PASS 44.1/48 kHz stereo: frame grid and channel separation")
    }

    private static func verifyNonFiniteTail(directory: URL) throws {
        let sampleRate = 48_000.0
        let frameLength = 1_024
        let count = frameLength + 17
        var channels = syntheticChannels(count: count, channelCount: 2, sampleRate: sampleRate)
        channels[1][count - 1] = .nan
        let analyzer = SpectrumAnalyzer(configuration: .init(
            frameDurationSeconds: Double(frameLength) / sampleRate,
            hopFraction: 0.25,
            minimumFrameLength: frameLength,
            maximumFrameLength: frameLength
        ))
        let url = directory.appendingPathComponent("nonfinite-tail.caf")
        try writeCAF(channels: channels, sampleRate: sampleRate, to: url)

        do {
            _ = try analyzer.analyze(samples: channels, sampleRate: sampleRate)
            throw VerificationError.failed("samples path accepted a non-finite tail")
        } catch ResonanceCoreError.nonFiniteAudioSample {
            // Expected.
        }
        do {
            _ = try analyzer.analyze(fileURL: url)
            throw VerificationError.failed("streaming file path accepted a non-finite tail")
        } catch ResonanceCoreError.nonFiniteAudioSample {
            // Expected.
        }
        print("PASS non-finite tail: validation covers samples outside the final FFT window")
    }

    private static func compareFileAndSamples(
        analyzer: SpectrumAnalyzer,
        channels: [[Float]],
        sampleRate: Double,
        url: URL,
        expectNoFrames: Bool = false
    ) throws {
        let id = UUID()
        let coverage = try Coverage(
            kind: .partial,
            mediaDurationSeconds: Double(channels[0].count) / sampleRate,
            recordedDurationSeconds: Double(channels[0].count) / sampleRate,
            intervals: [try TimeRange(startSeconds: 0, endSeconds: Double(channels[0].count) / sampleRate)],
            identityConfirmed: true
        )
        if expectNoFrames {
            try expectNoSpectrumFrames { try analyzer.analyze(samples: channels, sampleRate: sampleRate, coverage: coverage, recordingID: id) }
            try expectNoSpectrumFrames { try analyzer.analyze(fileURL: url, coverage: coverage, recordingID: id) }
            return
        }

        let expected = try analyzer.analyze(samples: channels, sampleRate: sampleRate, coverage: coverage, recordingID: id)
        let actual = try analyzer.analyze(fileURL: url, coverage: coverage, recordingID: id)
        guard expected == actual else {
            throw VerificationError.failed("streaming and samples paths differ for \(url.lastPathComponent)")
        }
        guard expected.frames.map(\.startTimeSeconds) == actual.frames.map(\.startTimeSeconds) else {
            throw VerificationError.failed("frame starts differ for \(url.lastPathComponent)")
        }
    }

    private static func expectNoSpectrumFrames<T>(_ body: () throws -> T) throws {
        do {
            _ = try body()
            throw VerificationError.failed("short audio unexpectedly produced a spectrum")
        } catch ResonanceCoreError.noSpectrumFrames {
            // Expected.
        }
    }

    private static func syntheticChannels(count: Int, channelCount: Int, sampleRate: Double) -> [[Float]] {
        (0..<channelCount).map { channel in
            (0..<count).map { index in
                let time = Double(index) / sampleRate
                let tone = 220.0 * Double(channel + 1) + 1_000.0
                return Float(0.2 * sin(2.0 * Double.pi * tone * time) + 0.03 * cos(2.0 * Double.pi * 73.0 * time))
            }
        }
    }

    private static func writeCAF(channels: [[Float]], sampleRate: Double, to url: URL) throws {
        guard let first = channels.first, !first.isEmpty,
              channels.allSatisfy({ $0.count == first.count }) else {
            throw VerificationError.failed("invalid synthetic channel fixture")
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(first.count)) else {
            throw VerificationError.failed("could not create synthetic CAF format")
        }
        buffer.frameLength = AVAudioFrameCount(first.count)
        guard let channelData = buffer.floatChannelData else {
            throw VerificationError.failed("synthetic CAF has no channel data")
        }
        for channel in channels.indices {
            channels[channel].withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else { return }
                channelData[channel].update(from: sourceBase, count: source.count)
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}

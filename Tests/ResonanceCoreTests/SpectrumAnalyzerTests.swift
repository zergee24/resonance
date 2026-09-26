import AVFoundation
import XCTest
@testable import ResonanceCore

final class SpectrumAnalyzerTests: XCTestCase {
    func testHannPSDPreservesStereoAndSampleRate() throws {
        let sampleRate = 48_000.0
        let frameLength = 1_024
        let sampleCount = frameLength * 3
        let left = (0..<sampleCount).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / sampleRate)) }
        let right = (0..<sampleCount).map { Float(sin(2 * Double.pi * 12_000 * Double($0) / sampleRate)) }
        let coverage = try Coverage(
            kind: .partial,
            intervals: [TimeRange(startSeconds: 0, endSeconds: Double(sampleCount) / sampleRate)]
        )
        let analyzer = SpectrumAnalyzer(configuration: .init(frameDurationSeconds: Double(frameLength) / sampleRate, minimumFrameLength: frameLength, maximumFrameLength: frameLength))
        let features = try analyzer.analyze(samples: [left, right], sampleRate: sampleRate, coverage: coverage)

        XCTAssertEqual(features.sampleRate, sampleRate)
        XCTAssertEqual(features.channelCount, 2)
        XCTAssertEqual(features.frames.count, 9, "The configured hop is frameLength / 4")
        XCTAssertEqual(features.frequencyBinsHz.last!, sampleRate / 2, accuracy: 1e-9)
        XCTAssertEqual(features.frames.first?.powerSpectralDensityByChannel.count, 2)

        let leftPeak = peakFrequency(features.frames[1].powerSpectralDensityByChannel[0], bins: features.frequencyBinsHz)
        let rightPeak = peakFrequency(features.frames[1].powerSpectralDensityByChannel[1], bins: features.frequencyBinsHz)
        XCTAssertEqual(leftPeak, 1_000, accuracy: sampleRate / Double(frameLength))
        XCTAssertEqual(rightPeak, 12_000, accuracy: sampleRate / Double(frameLength))
    }

    func testDecodesARealWAVFileWithoutDownmixing() throws {
        let sampleRate = 44_100.0
        let frameCount = 9_000
        let left = (0..<frameCount).map { Float(sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
        let right = (0..<frameCount).map { Float(sin(2 * Double.pi * 2_000 * Double($0) / sampleRate)) }
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("resonance-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<frameCount {
            channels[0][index] = left[index]
            channels[1][index] = right[index]
        }
        try file.write(from: buffer)

        let coverage = try Coverage(kind: .complete, intervals: [TimeRange(startSeconds: 0, endSeconds: Double(frameCount) / sampleRate)], identityConfirmed: true)
        let analyzer = SpectrumAnalyzer(configuration: .init(frameDurationSeconds: 0.05))
        let features = try analyzer.analyze(fileURL: url, coverage: coverage)
        XCTAssertEqual(features.sampleRate, sampleRate, accuracy: 1e-9)
        XCTAssertEqual(features.channelCount, 2)
        XCTAssertEqual(features.coverage.kind, .complete)
    }

    func testDecodesCAFAtExactAndNonExactReadChunkBoundaries() throws {
        let sampleRate = 48_000.0
        let analyzer = SpectrumAnalyzer(configuration: .init(frameDurationSeconds: 0.18))

        for frameCount in [65_536 * 2, 65_536 * 2 + 123] {
            let url = try writeCAF(frameCount: frameCount, sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: url) }

            let coverage = try Coverage(
                kind: .complete,
                intervals: [TimeRange(startSeconds: 0, endSeconds: Double(frameCount) / sampleRate)],
                identityConfirmed: true
            )
            let features = try analyzer.analyze(fileURL: url, coverage: coverage)

            XCTAssertEqual(features.sampleRate, sampleRate, accuracy: 1e-9)
            XCTAssertEqual(features.channelCount, 2)
            XCTAssertEqual(features.durationSeconds, Double(frameCount) / sampleRate, accuracy: 1e-9)
            XCTAssertFalse(features.frames.isEmpty)
        }
    }

    private func writeCAF(frameCount: Int, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-boundary-" + UUID().uuidString + ".caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for frame in 0..<frameCount {
            samples[frame * 2] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            samples[frame * 2 + 1] = Float(sin(2 * Double.pi * 2_000 * Double(frame) / sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    private func peakFrequency(_ psd: [Double], bins: [Double]) -> Double {
        guard let index = psd.indices.max(by: { psd[$0] < psd[$1] }) else { return .nan }
        return bins[index]
    }
}

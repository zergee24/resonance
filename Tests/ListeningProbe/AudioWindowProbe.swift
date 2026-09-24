import AVFoundation
import Darwin
import Foundation

@main
struct AudioWindowProbe {
    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
    }

    static func main() {
        do {
            try run()
            print("PASS audio-window probe")
        } catch {
            fputs("FAIL audio-window probe: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-audio-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("three-tones.caf")
        let trimmedURL = directory.appendingPathComponent("confirmed-window.caf")
        let fullTrimmedURL = directory.appendingPathComponent("confirmed-full-window.caf")
        let sampleRate = 48_000.0
        let segmentFrames = 20 * Int(sampleRate)
        let totalFrames = segmentFrames * 3
        let trimFrameCount = segmentFrames + 12_345

        try writeThreeToneSource(
            to: sourceURL,
            sampleRate: sampleRate,
            segmentFrames: segmentFrames
        )
        let sourceBefore = try Data(contentsOf: sourceURL)
        let endSeconds = (Double(trimFrameCount) + 0.75) / sampleRate
        let result = try CapturedAudioWindow.trim(
            fileURL: sourceURL,
            to: trimmedURL,
            endSeconds: endSeconds
        )

        try check(result.frameCount == Int64(trimFrameCount), "frame count was not floored to the requested frame")
        try check(result.sampleRate == sampleRate, "sample rate changed")
        try check(result.channelCount == 2, "channel count changed")
        try check(
            abs(result.durationSeconds - Double(trimFrameCount) / sampleRate) < 1e-12,
            "reported duration does not match copied frames"
        )
        try check(result.nonzeroFrames == Int64(trimFrameCount), "nonzero frame count was not computed from the copied window")

        let trimmed = try readFloatPCM(from: trimmedURL)
        try check(trimmed.frameCount == trimFrameCount, "destination contains an unexpected number of frames")
        try check(trimmed.sampleRate == sampleRate, "destination sample rate is not preserved")
        try check(trimmed.channelCount == 2, "destination channel count is not preserved")

        let checks = [
            (0, "first-tone start"),
            (segmentFrames - 1, "first-tone end"),
            (segmentFrames, "second-tone boundary"),
            (trimFrameCount - 1, "trimmed final frame")
        ]
        for (frame, label) in checks {
            let expected = expectedSamples(
                at: frame,
                sampleRate: sampleRate,
                segmentFrames: segmentFrames
            )
            try check(
                abs(trimmed.channels[0][frame] - expected.left) < 1e-5
                    && abs(trimmed.channels[1][frame] - expected.right) < 1e-5,
                "sample content mismatch at \(label)"
            )
        }

        // A full-length window is the production path for whole-song analysis.
        // Keeping this at 60 seconds catches accidental fixed-size or 30-second
        // limits and checks that the final segment survives the copy.
        let fullResult = try CapturedAudioWindow.trim(
            fileURL: sourceURL,
            to: fullTrimmedURL,
            endSeconds: Double(totalFrames) / sampleRate
        )
        try check(fullResult.frameCount == Int64(totalFrames), "full-length window was truncated")
        try check(abs(fullResult.durationSeconds - 60.0) < 1e-12, "full-length duration is not 60 seconds")
        try check(fullResult.sampleRate == sampleRate, "full-length sample rate changed")
        try check(fullResult.channelCount == 2, "full-length channel count changed")
        try check(fullResult.nonzeroFrames == Int64(totalFrames), "full-length nonzero frame count is incomplete")
        let tail = try readFloatFrame(from: fullTrimmedURL, at: totalFrames - 1)
        let expectedTail = expectedSamples(
            at: totalFrames - 1,
            sampleRate: sampleRate,
            segmentFrames: segmentFrames
        )
        try check(
            tail.sampleRate == sampleRate
                && tail.channelCount == 2
                && abs(tail.channels[0] - expectedTail.left) < 1e-5
                && abs(tail.channels[1] - expectedTail.right) < 1e-5,
            "full-length window lost the final 1760 Hz segment"
        )

        let sourceAfter = try Data(contentsOf: sourceURL)
        try check(sourceBefore == sourceAfter, "source bytes changed during trimming")

        try expectThrow("zero end") {
            _ = try CapturedAudioWindow.trim(fileURL: sourceURL, to: directory.appendingPathComponent("zero.caf"), endSeconds: 0)
        }
        try expectThrow("negative end") {
            _ = try CapturedAudioWindow.trim(fileURL: sourceURL, to: directory.appendingPathComponent("negative.caf"), endSeconds: -1)
        }
        try expectThrow("NaN end") {
            _ = try CapturedAudioWindow.trim(fileURL: sourceURL, to: directory.appendingPathComponent("nan.caf"), endSeconds: .nan)
        }
        try expectThrow("past-end window") {
            _ = try CapturedAudioWindow.trim(
                fileURL: sourceURL,
                to: directory.appendingPathComponent("past.caf"),
                endSeconds: Double(totalFrames) / sampleRate + 1 / sampleRate
            )
        }
        print("three-tone: 440 Hz/0.25 -> 880 Hz/0.50 -> 1760 Hz/0.75 over 60 seconds")
        print("short window: copied \(result.frameCount) frames; nonzero=\(result.nonzeroFrames)")
        print("full window: copied \(fullResult.frameCount) frames; duration=\(fullResult.durationSeconds)s; tail preserved")
        print("boundaries: zero, negative, NaN, and past-end rejected")
    }

    private static func writeThreeToneSource(
        to url: URL,
        sampleRate: Double,
        segmentFrames: Int
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw ProbeError(description: "could not create fixture format")
        }
        let totalFrames = segmentFrames * 3
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ), let channels = buffer.floatChannelData else {
            throw ProbeError(description: "could not allocate fixture buffer")
        }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        for frame in 0..<totalFrames {
            let segment = min(frame / segmentFrames, 2)
            let frequency = [440.0, 880.0, 1_760.0][segment]
            let amplitude = [0.25, 0.50, 0.75][segment]
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            channels[0][frame] = Float(amplitude * sin(phase))
            channels[1][frame] = Float(amplitude * cos(phase))
        }
        try file.write(from: buffer)
    }

    private static func expectedSamples(
        at frame: Int,
        sampleRate: Double,
        segmentFrames: Int
    ) -> (left: Float, right: Float) {
        let segment = min(frame / segmentFrames, 2)
        let frequency = [440.0, 880.0, 1_760.0][segment]
        let amplitude = [0.25, 0.50, 0.75][segment]
        let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
        return (
            Float(amplitude * sin(phase)),
            Float(amplitude * cos(phase))
        )
    }

    private struct FloatPCM {
        let sampleRate: Double
        let channelCount: Int
        let frameCount: Int
        let channels: [[Float]]
    }

    private static func readFloatPCM(from url: URL) throws -> FloatPCM {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frameCount = Int(file.length)
        let channelCount = Int(format.channelCount)
        guard frameCount > 0, channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else {
            throw ProbeError(description: "could not decode fixture output")
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        let actualFrames = Int(buffer.frameLength)
        let channels = (0..<channelCount).map { channel in
            Array(UnsafeBufferPointer(start: channelData[channel], count: actualFrames))
        }
        return FloatPCM(
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            frameCount: actualFrames,
            channels: channels
        )
    }

    private static func readFloatFrame(from url: URL, at frameIndex: Int) throws -> (sampleRate: Double, channelCount: Int, channels: [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard frameIndex >= 0, Int64(frameIndex) < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1),
              let channelData = buffer.floatChannelData else {
            throw ProbeError(description: "could not seek to fixture tail")
        }
        file.framePosition = AVAudioFramePosition(frameIndex)
        try file.read(into: buffer, frameCount: 1)
        guard buffer.frameLength == 1 else {
            throw ProbeError(description: "fixture tail frame was not readable")
        }
        return (
            format.sampleRate,
            Int(format.channelCount),
            (0..<Int(format.channelCount)).map { channelData[$0][0] }
        )
    }

    private static func expectThrow(_ label: String, operation: () throws -> Void) throws {
        do {
            try operation()
            throw ProbeError(description: "\(label) was accepted")
        } catch let error as ProbeError {
            throw error
        } catch {
            // Any error is sufficient for these invalid boundary cases.
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProbeError(description: message)
        }
    }
}

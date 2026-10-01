import Foundation
import AVFoundation
import ResonanceCore

// The harness compiles the production app sources without SwiftPM's resource
// bundle synthesis. This stub replaces only the resource-loading extension;
// the merger itself remains the production AppModel implementation.
extension AppModel {
    func loadPersonalReferenceSamples() throws {}
    func loadRaphaelSample() {}
}

@main
struct RecordingMergeHarness {
    static func main() throws {
        try checkSingleSegmentKeepsSTFTOverlap()
        try checkDisjointOffsets()
        try checkCrossSegmentOverlap()
        try checkRejectsUnknownOffsetAndGrid()
        try checkShortSegmentEligibilityAndFilteredAggregation()
        print("recording merge harness: PASS")
    }

    private static func checkShortSegmentEligibilityAndFilteredAggregation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-short-segment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sampleRate = 48_000.0
        let frameLength = 8_192
        let analyzer = SpectrumAnalyzer(configuration: .init(
            frameDurationSeconds: Double(frameLength) / sampleRate,
            minimumFrameLength: frameLength,
            maximumFrameLength: frameLength
        ))
        var validFeature: SpectrumFeatures?
        var validURL: URL?
        var shortURL: URL?
        for sampleCount in [8_191, 8_192, 8_193] {
            let url = try writePCM(sampleCount: sampleCount, sampleRate: sampleRate, directory: directory)
            let original = try Data(contentsOf: url)
            let eligibility = try analyzer.inputEligibility(fileURL: url)
            let productionEligibility = try AppModel.recordingAnalysisEligibility(segmentID: UUID(), audioURL: url)
            try require(eligibility.sampleCount == Int64(sampleCount), "eligibility sample count changed")
            try require(eligibility.requiredFrameLength == frameLength, "eligibility did not use the configured frame length")
            try require(eligibility.hasSpectrumFrame == (sampleCount >= frameLength), "short/valid frame boundary was classified incorrectly")
            try require(
                productionEligibility.action == (sampleCount >= frameLength ? .analyze : .waitForMoreAudio),
                "recording queue eligibility disagrees with the analyzer"
            )
            if sampleCount < frameLength {
                shortURL = url
                do {
                    _ = try analyzer.analyze(fileURL: url)
                    throw HarnessError(message: "short segment unexpectedly produced a spectrum")
                } catch ResonanceCoreError.noSpectrumFrames {
                    // The production recording path filters this known input
                    // condition before analysis; no zero-padding is allowed.
                }
            } else {
                validFeature = try analyzer.analyze(fileURL: url)
                validURL = url
            }
            try require(Data(contentsOf: url) == original, "analysis modified the source PCM/container")
        }

        guard let validFeature, let validURL, let shortURL else {
            throw HarnessError(message: "valid boundary sample did not produce a feature")
        }
        let shortDecision = try AppModel.recordingAnalysisEligibility(segmentID: UUID(), audioURL: shortURL)
        let validDecision = try AppModel.recordingAnalysisEligibility(segmentID: UUID(), audioURL: validURL)
        try require(shortDecision.action == .waitForMoreAudio, "all-short row did not remain deferred")
        try require(validDecision.action == .analyze, "a later valid segment was not eligible for recovery")
        let validDuration = Double(8_193) / sampleRate
        let validID = UUID()
        let validSegment = RecordingSegment(
            id: validID,
            audioPath: validURL.path,
            mediaStartSeconds: 1,
            capturedSeconds: validDuration,
            sampleRate: sampleRate,
            channels: 1
        )
        let validCoverage = try Coverage(
            kind: .partial,
            mediaDurationSeconds: 2,
            recordedDurationSeconds: validDuration,
            intervals: [try TimeRange(startSeconds: 1, endSeconds: 1 + validDuration)]
        )
        let merged = try AppModel.mergeFeatures(
            [(validSegment, validFeature)],
            track: TrackEntry(title: "short + valid", artist: "", duration: 2),
            coverage: validCoverage
        )
        try require(merged.frames.count == validFeature.frames.count, "valid segment was lost when a short segment was present")
        try require(merged.coverage == validCoverage, "aggregate coverage included the deferred short segment")
        try require(!merged.coverage.intervals.contains(where: { $0.startSeconds == 0 }), "short segment was advertised in aggregate coverage")

        print("PASS short segments: 8191 waits, 8192/8193 analyze, PCM preserved, aggregate excludes deferred short input")
    }

    private static func writePCM(sampleCount: Int, sampleRate: Double, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(sampleCount)-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let file = try? AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw HarnessError(message: "could not create synthetic CAF")
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<sampleCount {
                channel[index] = Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    private static func checkSingleSegmentKeepsSTFTOverlap() throws {
        let id = UUID()
        let feature = try feature(id: id, starts: [0, 0.25, 0.5])
        let segment = RecordingSegment(id: id, audioPath: "/tmp/one.caf", capturedSeconds: 1, sampleRate: 100, channels: 1)
        let merged = try AppModel.mergeFeatures(
            [(segment, feature)],
            track: TrackEntry(title: "one", artist: "", duration: 1),
            coverage: try Coverage(kind: .partial, recordedDurationSeconds: 1)
        )
        try require(merged.frames.count == 3, "intra-segment STFT windows were dropped")
    }

    private static func checkDisjointOffsets() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = try feature(id: firstID, starts: [0, 1])
        let second = try feature(id: secondID, starts: [0, 1])
        let segments = [
            RecordingSegment(id: firstID, audioPath: "/tmp/one.caf", mediaStartSeconds: 0, capturedSeconds: 2, sampleRate: 100, channels: 1),
            RecordingSegment(id: secondID, audioPath: "/tmp/two.caf", mediaStartSeconds: 10, capturedSeconds: 2, sampleRate: 100, channels: 1)
        ]
        let merged = try AppModel.mergeFeatures(
            Array(zip(segments, [first, second])),
            track: TrackEntry(title: "two", artist: "", duration: 12),
            coverage: try Coverage(kind: .partial, recordedDurationSeconds: 4)
        )
        try require(merged.frames.count == 4, "disjoint segments changed frame count")
        try require(merged.frames.map { $0.startTimeSeconds } == [0, 1, 10, 11], "media offsets were not preserved")
    }

    private static func checkCrossSegmentOverlap() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = try feature(id: firstID, starts: [0, 1, 2])
        let second = try feature(id: secondID, starts: [0, 1, 2])
        let segments = [
            RecordingSegment(id: firstID, audioPath: "/tmp/one.caf", mediaStartSeconds: 0, capturedSeconds: 3, sampleRate: 100, channels: 1),
            RecordingSegment(id: secondID, audioPath: "/tmp/two.caf", mediaStartSeconds: 1, capturedSeconds: 3, sampleRate: 100, channels: 1)
        ]
        let merged = try AppModel.mergeFeatures(
            Array(zip(segments, [first, second])),
            track: TrackEntry(title: "overlap", artist: "", duration: 4),
            coverage: try Coverage(kind: .partial, recordedDurationSeconds: 4)
        )
        try require(merged.frames.count == 4, "overlapping segments were double-counted")
        try require(merged.frames.map { $0.startTimeSeconds } == [0, 1, 2, 3], "overlap ownership is incorrect")
    }

    private static func checkRejectsUnknownOffsetAndGrid() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = try feature(id: firstID, starts: [0, 1])
        let second = try feature(id: secondID, starts: [0, 1], bins: [0, 60])
        let track = TrackEntry(title: "invalid", artist: "", duration: 4)
        let unknownOffset = [
            (RecordingSegment(id: firstID, audioPath: "/tmp/one.caf", mediaStartSeconds: 0, capturedSeconds: 2, sampleRate: 100, channels: 1), first),
            (RecordingSegment(id: secondID, audioPath: "/tmp/two.caf", capturedSeconds: 2, sampleRate: 100, channels: 1), first)
        ]
        try requireThrows {
            _ = try AppModel.mergeFeatures(unknownOffset, track: track, coverage: try Coverage(kind: .partial, recordedDurationSeconds: 4))
        }
        try requireThrows {
            _ = try AppModel.mergeFeatures(
                [
                    (RecordingSegment(id: firstID, audioPath: "/tmp/one.caf", mediaStartSeconds: 0, capturedSeconds: 2, sampleRate: 100, channels: 1), first),
                    (RecordingSegment(id: secondID, audioPath: "/tmp/two.caf", mediaStartSeconds: 2, capturedSeconds: 2, sampleRate: 100, channels: 1), second)
                ],
                track: track,
                coverage: try Coverage(kind: .partial, recordedDurationSeconds: 4)
            )
        }
    }

    private static func feature(id: UUID, starts: [Double], bins: [Double] = [0, 50]) throws -> SpectrumFeatures {
        let coverage = try Coverage(kind: .partial, recordedDurationSeconds: 3)
        let parameters = SpectrumAnalysisParameters(frameLength: 100, hopLength: 100, frameDurationSeconds: 1)
        return SpectrumFeatures(
            recordingID: id,
            sampleRate: 100,
            channelCount: 1,
            frequencyBinsHz: bins,
            frames: starts.map { SpectrumFrame(startTimeSeconds: $0, sampleCount: 100, powerSpectralDensityByChannel: [[1, 2]]) },
            durationSeconds: 3,
            coverage: coverage,
            validMinHz: bins.first ?? 0,
            validMaxHz: bins.last ?? 0,
            frequencyValidity: .mathematicalNyquist,
            format: AudioFormatMetadata(sampleRate: 100, channelCount: 1),
            parameters: parameters,
            analyzerVersion: "harness"
        )
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw HarnessError(message: message) }
    }

    private static func requireThrows(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            return
        }
        throw HarnessError(message: "production merger accepted invalid input")
    }

    private struct HarnessError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

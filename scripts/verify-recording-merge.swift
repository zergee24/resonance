import Foundation
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
        print("recording merge harness: PASS")
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

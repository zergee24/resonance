import Foundation
import ResonanceCore

private enum HarnessError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case let .failed(message): return message }
    }
}

@main
struct RawAudioCacheHarness {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resonance-raw-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalStore(directory: root.appendingPathComponent("store"))
        let external = root.appendingPathComponent("external", isDirectory: true)
        let externalAudio = external.appendingPathComponent("Audio", isDirectory: true)
        let externalFeatures = external.appendingPathComponent("Features", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: store.directory.appendingPathComponent("Audio"), to: externalAudio)
        try FileManager.default.moveItem(at: store.directory.appendingPathComponent("Features"), to: externalFeatures)
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("Audio"), withDestinationURL: externalAudio)
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("Features"), withDestinationURL: externalFeatures)
        let audio = store.directory.appendingPathComponent("Audio", isDirectory: true)
        let features = store.directory.appendingPathComponent("Features", isDirectory: true)
        let oldEligible = try makeAudio(audio, name: "old-eligible.caf", bytes: 300)
        let shared = try makeAudio(audio, name: "shared-protected.caf", bytes: 100)
        let pending = try makeAudio(audio, name: "pending.caf", bytes: 20)
        let failed = try makeAudio(audio, name: "failed.caf", bytes: 20)
        let short = try makeAudio(audio, name: "short.caf", bytes: 20)
        let active = try makeAudio(audio, name: "capture-current.caf", bytes: 20)
        let unknown = try makeAudio(audio, name: "unknown.caf", bytes: 20)
        let outside = root.appendingPathComponent("outside.caf")
        try Data(repeating: 0, count: 20).write(to: outside)
        let symlink = audio.appendingPathComponent("linked.caf")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: oldEligible.path)

        try setDate(oldEligible, seconds: 100)
        try setDate(shared, seconds: 200)
        try setDate(pending, seconds: 300)
        try setDate(failed, seconds: 400)
        try setDate(short, seconds: 500)
        try setDate(active, seconds: 600)
        try setDate(unknown, seconds: 700)

        var tracks: [TrackEntry] = []
        tracks.append(try track(audio: oldEligible, features: features, name: "eligible"))
        tracks.append(try track(audio: shared, features: features, name: "shared-safe"))
        var sharedFailure = TrackEntry(title: "shared-failure", artist: "fixture", duration: 1, capturedSeconds: 1)
        sharedFailure.processingState = "频谱分析失败，等待下次恢复"
        sharedFailure.recordingSegments = [RecordingSegment(audioPath: shared.path, capturedSeconds: 1)]
        tracks.append(sharedFailure)

        var pendingTrack = try track(audio: pending, features: features, name: "pending")
        tracks.append(pendingTrack)
        var failedTrack = try track(audio: failed, features: features, name: "failed")
        failedTrack.error = "等待人工恢复"
        tracks.append(failedTrack)

        var shortTrack = TrackEntry(title: "short", artist: "fixture", duration: 1, capturedSeconds: 1)
        shortTrack.recordingSegments = [RecordingSegment(audioPath: short.path, capturedSeconds: 1)]
        tracks.append(shortTrack)

        var activeTrack = try track(audio: active, features: features, name: "active")
        tracks.append(activeTrack)

        var outsideTrack = try track(audio: outside, features: features, name: "outside")
        tracks.append(outsideTrack)

        let pendingIDs: Set<UUID> = [pendingTrack.id, activeTrack.id]
        let snapshot = RawAudioCache.snapshot(tracks: tracks, pendingTrackIDs: pendingIDs)
        let plan = try RawAudioCache.makePlan(directory: store.directory, snapshot: snapshot, targetBytes: 250)
        let canonicalOldEligible = oldEligible.resolvingSymlinksInPath().standardizedFileURL.path
        try check(plan.candidates.map(\.path) == [canonicalOldEligible], "oldest eligible CAF was not the only planned deletion")
        let eligibleFeatureURL = URL(fileURLWithPath: tracks[0].analysisSegments[0].featurePath!)
        let eligibleFeatureBytes = try Data(contentsOf: eligibleFeatureURL)
        try Data(repeating: 7, count: eligibleFeatureBytes.count).write(to: eligibleFeatureURL, options: .atomic)
        let stalePlanResult = RawAudioCache.apply(plan, directory: store.directory, snapshot: snapshot)
        try check(stalePlanResult.deletedFiles == 0 && FileManager.default.fileExists(atPath: oldEligible.path), "cache deleted audio after its verified feature changed")
        try eligibleFeatureBytes.write(to: eligibleFeatureURL, options: .atomic)
        let freshPlan = try RawAudioCache.makePlan(directory: store.directory, snapshot: snapshot, targetBytes: 250)
        let result = RawAudioCache.apply(freshPlan, directory: store.directory, snapshot: snapshot)
        try check(result.deletedFiles == 1 && result.deletedBytes == 300, "cache did not delete only the eligible old CAF")
        try check(!FileManager.default.fileExists(atPath: oldEligible.path), "eligible old CAF remains")
        try check(FileManager.default.fileExists(atPath: shared.path), "shared-reference CAF was deleted")
        try check(FileManager.default.fileExists(atPath: pending.path), "pending CAF was deleted")
        try check(FileManager.default.fileExists(atPath: failed.path), "failed CAF was deleted")
        try check(FileManager.default.fileExists(atPath: short.path), "short-segment CAF was deleted")
        try check(FileManager.default.fileExists(atPath: active.path), "current capture CAF was deleted")
        try check(FileManager.default.fileExists(atPath: unknown.path), "unknown CAF was deleted")
        let symlinkValues = try symlink.resourceValues(forKeys: [.isSymbolicLinkKey])
        try check(symlinkValues.isSymbolicLink == true, "symlink was deleted")
        try check(FileManager.default.fileExists(atPath: outside.path), "outside CAF was deleted")
        print("PASS raw cache: 2 GB policy shape, oldest eligible deletion, shared/pending/error/short/current/unknown/symlink/outside protection")
    }

    static func track(audio: URL, features: URL, name: String) throws -> TrackEntry {
        let trackID = UUID()
        let segmentID = UUID()
        let featureURL = features.appendingPathComponent("\(segmentID.uuidString).plist.lzfse")
        let feature = SpectrumFeatures(
            recordingID: segmentID,
            sampleRate: 48_000,
            channelCount: 1,
            frequencyBinsHz: [0, 24_000],
            frames: [SpectrumFrame(startTimeSeconds: 0, sampleCount: 256, powerSpectralDensityByChannel: [[1, 1]])],
            durationSeconds: 1,
            coverage: try Coverage(kind: .complete, mediaDurationSeconds: 1, recordedDurationSeconds: 1, intervals: [try TimeRange(startSeconds: 0, endSeconds: 1)]),
            validMinHz: 0,
            validMaxHz: 24_000,
            frequencyValidity: .mathematicalNyquist,
            format: AudioFormatMetadata(sampleRate: 48_000, channelCount: 1),
            parameters: SpectrumAnalysisParameters(frameLength: 256, hopLength: 64, frameDurationSeconds: 256.0 / 48_000),
            analyzerVersion: "fixture"
        )
        try LocalStore.writeArtifact(feature, to: featureURL)
        var track = TrackEntry(id: trackID, title: name, artist: "fixture", audioPath: audio.path, featurePath: featureURL.path, duration: 1, capturedSeconds: 1, isFull: true)
        track.recordingSegments = [RecordingSegment(id: segmentID, audioPath: audio.path, featurePath: featureURL.path, capturedSeconds: 1, sampleRate: 48_000, channels: 1)]
        return track
    }

    static func makeAudio(_ directory: URL, name: String, bytes: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    static func setDate(_ url: URL, seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw HarnessError.failed(message) }
    }
}

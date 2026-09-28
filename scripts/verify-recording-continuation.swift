import Foundation
import ResonanceCore

// The production PlayerSnapshot is AppKit-backed. This narrow harness supplies
// only the identity fields used by RecordingContinuation.
struct PlayerSnapshot {
    let trackID: String?
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let sourceBundleIdentifier: String?
    let systemItemIdentifier: String?
}

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

@main
private struct RecordingContinuationVerification {
    static func main() throws {
        let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var legacy = TrackEntry(
            id: legacyID,
            title: "Legacy",
            artist: "Artist",
            audioPath: "/tmp/legacy.caf",
            featurePath: "/tmp/legacy.plist",
            duration: 10,
            capturedSeconds: 10,
            isFull: true
        )
        legacy.mediaStartSeconds = 0
        try verifyLegacyDecode(legacy)
        var failedLegacy = legacy
        failedLegacy.processingState = "采集无有效音频"
        let failedSnapshot = PlayerSnapshot(trackID: nil, title: "Legacy", artist: "Artist", album: "Album", duration: 10, sourceBundleIdentifier: "com.netease.163music", systemItemIdentifier: "failed")
        try check(RecordingContinuation.matchingTrack(for: failedSnapshot, in: [failedLegacy]) == nil, "failed legacy capture was considered reusable")

        let original = segment(id: legacyID, path: "/tmp/legacy.caf", start: 0, duration: 278)
        var partial = TrackEntry(title: "Long", artist: "Artist", neteaseID: "123", duration: 296, capturedSeconds: 278)
        partial.recordingSegments = [original]

        let covered = RecordingContinuation.unionCoverage(for: partial)
        try check(covered == [try TimeRange(startSeconds: 0, endSeconds: 278)], "single segment coverage changed")
        let atBoundary = RecordingContinuation.decision(for: partial, duration: 296, currentPosition: 278)
        try check(atBoundary.action == .waitForUncoveredPosition, "position at captured tail should wait")
        try check(atBoundary.gaps == [try TimeRange(startSeconds: 278, endSeconds: 296)], "18 second tail gap was not preserved")
        try check(RecordingContinuation.isWithinCoveredRange(for: partial, currentPosition: 278), "covered endpoint was not recognized")
        try check(!RecordingContinuation.isWithinCoveredRange(for: partial, currentPosition: 280), "an actual uncovered position was treated as covered")
        let afterBoundary = RecordingContinuation.decision(for: partial, duration: 296, currentPosition: 282.5)
        try check(afterBoundary.action == .capture, "position past uncovered tail should capture")
        try check(!RecordingContinuation.hasSufficientCoverage(track: partial, duration: 296), "18 second tail was treated as sufficient")

        let overlapA = segment(path: "/tmp/a.caf", start: 0, duration: 100)
        let overlapB = segment(path: "/tmp/b.caf", start: 90, duration: 50)
        var overlap = TrackEntry(title: "Overlap", artist: "Artist", duration: 200)
        overlap.recordingSegments = [overlapA, overlapB]
        try check(
            RecordingContinuation.unionCoverage(for: overlap) == [try TimeRange(startSeconds: 0, endSeconds: 140)],
            "overlapping segments were counted twice"
        )

        var sufficient = TrackEntry(title: "Complete", artist: "Artist", duration: 296)
        sufficient.recordingSegments = [segment(path: "/tmp/complete.caf", start: 0, duration: 295)]
        try check(
            RecordingContinuation.decision(for: sufficient, duration: 296, currentPosition: 1).action == .reuseExisting,
            "small boundary difference did not reuse existing coverage"
        )

        let continuation = segment(id: legacyID, path: "/tmp/continuation.caf", start: 278, duration: 18)
        RecordingContinuation.append(continuation, to: &partial)
        try check(partial.analysisSegments.count == 2, "continuation did not append a second segment")
        try check(partial.analysisSegments[0].id == legacyID, "legacy first segment ID was not preserved")
        try check(partial.analysisSegments[0].audioPath == "/tmp/legacy.caf", "legacy audio path was overwritten")
        try check(partial.analysisSegments[1].audioPath == "/tmp/continuation.caf", "continuation did not keep its independent CAF")

        let exactTrack = TrackEntry(title: "One", artist: "Same", album: "Album", neteaseID: "123", audioPath: "/tmp/one.caf", duration: 10, capturedSeconds: 10)
        let sameTitleDifferentID = TrackEntry(title: "One", artist: "Same", album: "Album", neteaseID: "456", audioPath: "/tmp/two.caf", duration: 10, capturedSeconds: 10)
        let exactSnapshot = PlayerSnapshot(trackID: "123", title: nil, artist: nil, album: nil, duration: 10, sourceBundleIdentifier: "com.netease.163music", systemItemIdentifier: "opaque-1")
        try check(RecordingContinuation.matchingTrack(for: exactSnapshot, in: [sameTitleDifferentID, exactTrack])?.neteaseID == "123", "exact NetEase ID did not win")
        let differentSnapshot = PlayerSnapshot(trackID: "999", title: "One", artist: "Same", album: "Other", duration: 10, sourceBundleIdentifier: "com.netease.163music", systemItemIdentifier: "opaque-other")
        try check(RecordingContinuation.matchingTrack(for: differentSnapshot, in: [sameTitleDifferentID, exactTrack]) == nil, "same title with a different NetEase ID was merged")
        let sameMetadataDifferentID = PlayerSnapshot(trackID: "999", title: "One", artist: "Same", album: "Album", duration: 10, sourceBundleIdentifier: "com.netease.163music", systemItemIdentifier: "opaque-other-2")
        try check(RecordingContinuation.matchingTrack(for: sameMetadataDifferentID, in: [exactTrack]) == nil, "metadata fallback crossed a conflicting exact NetEase ID")

        var opaqueTrack = TrackEntry(title: "Intro + A Moment Apart", artist: "Creed", album: "Intro + A Moment Apart", audioPath: "/tmp/opaque.caf", duration: 298.125, capturedSeconds: 10)
        opaqueTrack.sourceBundleIdentifier = "com.netease.163music"
        opaqueTrack.systemItemIdentifier = "opaque-old"
        let opaqueSnapshot = PlayerSnapshot(trackID: nil, title: "Intro + A Moment Apart", artist: "Creed", album: "Intro + A Moment Apart", duration: 298.125, sourceBundleIdentifier: "com.netease.163music", systemItemIdentifier: "opaque-new")
        try check(RecordingContinuation.matchingTrack(for: opaqueSnapshot, in: [opaqueTrack])?.id == opaqueTrack.id, "changed opaque ID with full metadata did not reuse")

        var differentAlbum = opaqueTrack
        differentAlbum.album = "Different Album"
        let differentAlbumSnapshot = PlayerSnapshot(trackID: nil, title: opaqueSnapshot.title, artist: opaqueSnapshot.artist, album: opaqueSnapshot.album, duration: opaqueSnapshot.duration, sourceBundleIdentifier: opaqueSnapshot.sourceBundleIdentifier, systemItemIdentifier: "opaque-new-2")
        try check(RecordingContinuation.matchingTrack(for: differentAlbumSnapshot, in: [differentAlbum]) == nil, "different album was merged")
        var differentDuration = opaqueTrack
        differentDuration.duration = 300
        try check(RecordingContinuation.matchingTrack(for: opaqueSnapshot, in: [differentDuration]) == nil, "different duration was merged")

        var conflictingID = opaqueTrack
        conflictingID.id = UUID()
        conflictingID.neteaseID = "conflicting-id"
        opaqueTrack.neteaseID = "original-id"
        try check(RecordingContinuation.matchingTrack(for: opaqueSnapshot, in: [opaqueTrack, conflictingID]) == nil, "conflicting NetEase IDs were merged")

        print("PASS legacy fallback, exact-ID reuse, changed-system-identity full-metadata reuse, metadata mismatch/conflict rejection, overlap union, 278+18 tail, and independent continuation append")
    }

    private static func segment(
        id: UUID = UUID(),
        path: String,
        start: Double,
        duration: Double
    ) -> RecordingSegment {
        RecordingSegment(id: id, audioPath: path, mediaStartSeconds: start, capturedSeconds: duration)
    }

    private static func verifyLegacyDecode(_ track: TrackEntry) throws {
        let encoder = JSONEncoder()
        let originalData = try encoder.encode(track)
        var object = try checkValue(JSONSerialization.jsonObject(with: originalData) as? [String: Any], "legacy fixture is not an object")
        object.removeValue(forKey: "album")
        object.removeValue(forKey: "recordingSegments")
        object.removeValue(forKey: "systemItemIdentifier")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TrackEntry.self, from: legacyData)
        try check(decoded.recordingSegments == nil, "legacy payload unexpectedly gained segments")
        try check(decoded.analysisSegments.count == 1, "legacy single-file fallback did not produce one segment")
        try check(decoded.analysisSegments[0].id == track.id, "legacy fallback segment did not use track ID")
        try check(decoded.analysisSegments[0].audioPath == track.audioPath, "legacy fallback path changed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError.failed(message) }
    }

    private static func checkValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw VerificationError.failed(message) }
        return value
    }
}

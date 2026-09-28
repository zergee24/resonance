import Foundation
import ResonanceCore

enum RecordingContinuationAction: Equatable {
    case capture
    case waitForUncoveredPosition
    case reuseExisting
}

struct RecordingContinuationDecision: Equatable {
    let action: RecordingContinuationAction
    let coverage: [TimeRange]
    let gaps: [TimeRange]
}

/// Small, deterministic rules for reusing an automatic recording and adding
/// only media-time ranges that are not already covered.
enum RecordingContinuation {
    static let coverageToleranceSeconds = 3.0
    static let metadataDurationToleranceSeconds = 1.0

    static func append(_ segment: RecordingSegment, to track: inout TrackEntry) {
        var segments = track.analysisSegments
        if let index = segments.firstIndex(where: { $0.id == segment.id && $0.audioPath == segment.audioPath }) {
            segments[index] = segment
        } else {
            segments.append(segment)
        }
        track.recordingSegments = segments
        if track.audioPath == nil { track.audioPath = segments.first?.audioPath }
        if track.featurePath == nil { track.featurePath = segments.first?.featurePath }
    }

    static func unionCoverage(for track: TrackEntry) -> [TimeRange] {
        unionCoverage(for: track.analysisSegments)
    }

    static func unionCoverage(for segments: [RecordingSegment]) -> [TimeRange] {
        let intervals = segments.compactMap { segment -> TimeRange? in
            guard let start = segment.mediaStartSeconds,
                  start.isFinite, start >= 0,
                  segment.capturedSeconds.isFinite, segment.capturedSeconds > 0 else { return nil }
            let end = start + segment.capturedSeconds
            guard end.isFinite, end >= start else { return nil }
            return try? TimeRange(startSeconds: start, endSeconds: end)
        }.sorted { $0.startSeconds < $1.startSeconds }

        guard var current = intervals.first else { return [] }
        var merged: [TimeRange] = []
        for interval in intervals.dropFirst() {
            if interval.startSeconds <= current.endSeconds {
                if interval.endSeconds > current.endSeconds {
                    current = try! TimeRange(startSeconds: current.startSeconds, endSeconds: interval.endSeconds)
                }
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }

    static func decision(
        for track: TrackEntry,
        duration: Double?,
        currentPosition: Double?
    ) -> RecordingContinuationDecision {
        let coverage = unionCoverage(for: track)
        let gaps = uncoveredRanges(coverage: coverage, duration: duration)
        if hasSufficientCoverage(track: track, duration: duration, coverage: coverage) {
            return RecordingContinuationDecision(action: .reuseExisting, coverage: coverage, gaps: gaps)
        }

        guard let currentPosition, currentPosition.isFinite, currentPosition >= 0 else {
            return RecordingContinuationDecision(action: .capture, coverage: coverage, gaps: gaps)
        }
        return RecordingContinuationDecision(
            action: isWithinCoveredRange(coverage: coverage, currentPosition: currentPosition) ? .waitForUncoveredPosition : .capture,
            coverage: coverage,
            gaps: gaps
        )
    }

    static func isWithinCoveredRange(for track: TrackEntry, currentPosition: Double) -> Bool {
        isWithinCoveredRange(coverage: unionCoverage(for: track), currentPosition: currentPosition)
    }

    static func hasSufficientCoverage(
        track: TrackEntry,
        duration: Double?,
        coverage: [TimeRange]? = nil
    ) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        let intervals = coverage ?? unionCoverage(for: track)
        if intervals.isEmpty {
            // A legacy imported full file has no media start, so this is an
            // estimate only. Recorded segments with known media starts always
            // take the interval-union path above; isFull is not a hard gate.
            return track.capturedSeconds.isFinite && track.capturedSeconds >= duration - coverageToleranceSeconds
        }
        return uncoveredRanges(coverage: intervals, duration: duration).allSatisfy { $0.durationSeconds <= coverageToleranceSeconds }
    }

    static func matchingTrack(for snapshot: PlayerSnapshot, in tracks: [TrackEntry]) -> TrackEntry? {
        let exactID = normalized(snapshot.trackID)
        if let exactID {
            let candidates = tracks
                .filter { hasRecordedAudio($0) && normalized($0.neteaseID) == exactID }
            if let exact = bestCandidate(candidates, duration: snapshot.duration) { return exact }
        }

        guard let bundle = normalized(snapshot.sourceBundleIdentifier),
              let title = normalized(snapshot.title),
              let artist = normalized(snapshot.artist),
              let album = normalized(snapshot.album),
              let duration = snapshot.duration,
              duration.isFinite, duration > 0 else { return nil }
        let candidates = tracks.filter {
            let candidateID = normalized($0.neteaseID)
            guard exactID == nil || candidateID == nil || candidateID == exactID else { return false }
            guard hasRecordedAudio($0),
                  normalized($0.sourceBundleIdentifier) == bundle,
                  normalized($0.title) == title,
                  normalized($0.artist) == artist,
                  normalized($0.album) == album,
                  let candidateDuration = $0.duration,
                  candidateDuration.isFinite, candidateDuration > 0 else { return false }
            return abs(candidateDuration - duration) <= metadataDurationToleranceSeconds
        }
        let candidateIDs = Set(candidates.compactMap { normalized($0.neteaseID) })
        guard candidateIDs.count <= 1 else { return nil }
        return bestCandidate(candidates, duration: snapshot.duration)
    }

    static func matchingAnalyzedTrack(for snapshot: PlayerSnapshot, in tracks: [TrackEntry]) -> TrackEntry? {
        matchingTrack(for: snapshot, in: tracks.filter(\.analyzed))
    }

    private static func hasRecordedAudio(_ track: TrackEntry) -> Bool {
        if track.recordingSegments == nil,
           ["采集写入失败", "采集格式无效", "采集无有效音频"].contains(track.processingState) {
            return false
        }
        return track.analysisSegments.contains {
            !$0.audioPath.isEmpty && $0.capturedSeconds.isFinite && $0.capturedSeconds > 0
        }
    }

    private static func bestCandidate(_ candidates: [TrackEntry], duration: Double?) -> TrackEntry? {
        candidates.max { lhs, rhs in
            let lhsSufficient = hasSufficientCoverage(track: lhs, duration: duration)
            let rhsSufficient = hasSufficientCoverage(track: rhs, duration: duration)
            if lhsSufficient != rhsSufficient { return !lhsSufficient && rhsSufficient }
            let lhsCoverage = unionCoverage(for: lhs).reduce(0) { $0 + $1.durationSeconds }
            let rhsCoverage = unionCoverage(for: rhs).reduce(0) { $0 + $1.durationSeconds }
            if lhsCoverage != rhsCoverage { return lhsCoverage < rhsCoverage }
            return lhs.importedAt < rhs.importedAt
        }
    }

    private static func uncoveredRanges(coverage: [TimeRange], duration: Double?) -> [TimeRange] {
        guard let duration, duration.isFinite, duration > 0 else { return [] }
        var cursor = 0.0
        var gaps: [TimeRange] = []
        for interval in coverage where interval.endSeconds > 0 {
            let start = max(0, interval.startSeconds)
            let end = min(duration, interval.endSeconds)
            guard end > start else { continue }
            if start > cursor {
                if let gap = try? TimeRange(startSeconds: cursor, endSeconds: start) { gaps.append(gap) }
            }
            cursor = max(cursor, end)
            if cursor >= duration { break }
        }
        if cursor < duration, let gap = try? TimeRange(startSeconds: cursor, endSeconds: duration) {
            gaps.append(gap)
        }
        return gaps
    }

    private static func isWithinCoveredRange(coverage: [TimeRange], currentPosition: Double) -> Bool {
        guard currentPosition.isFinite, currentPosition >= 0 else { return false }
        return coverage.contains {
            currentPosition >= $0.startSeconds && currentPosition <= $0.endSeconds
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

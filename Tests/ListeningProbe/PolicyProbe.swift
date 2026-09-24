import Darwin
import Foundation

@main
struct PolicyProbe {
    private static var checks = 0

    static func main() {
        verifyPreferenceDefaultsAndPersistence()
        verifyFirstPlayAndRepeatedPolling()
        verifyPauseResumeAndTrackChange()
        verifyDisableAndReenable()
        verifyAttemptOnlyOnce()
        verifyStabilityDelayAndSeek()
        verifyUnknownAndStoppedPlayback()
        print("PASS: \(checks) automatic-listening policy checks")
    }

    private static func verifyPreferenceDefaultsAndPersistence() {
        let suiteName = "resonance-listening-policy-probe-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fail("could not create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)

        require(
            AutomaticListeningPreference.isEnabled(in: defaults),
            "an absent preference defaults to enabled"
        )
        require(
            defaults.object(forKey: AutomaticListeningPreference.key) == nil,
            "reading the default does not write a preference"
        )

        AutomaticListeningPreference.setEnabled(false, in: defaults)
        require(
            !AutomaticListeningPreference.isEnabled(in: defaults),
            "a disabled preference persists as false"
        )
        AutomaticListeningPreference.setEnabled(true, in: defaults)
        require(
            AutomaticListeningPreference.isEnabled(in: defaults),
            "re-enabling persists as true"
        )
    }

    private static func verifyFirstPlayAndRepeatedPolling() {
        let start = Date(timeIntervalSince1970: 1_000)
        var policy = AutomaticListeningPolicy()

        let first = policy.update(candidateKey: "song-a", isPlaying: true, now: start)
        require(first.newSession, "first playing identity creates a session")
        require(first.shouldCreateHistory, "first session creates one history event")
        require(first.sessionID != nil, "first session has an ID")
        require(first.readyToCapture, "default stability delay is zero")

        let repeated = policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(0.5))
        require(!repeated.newSession, "repeated poll does not create a session")
        require(!repeated.shouldCreateHistory, "repeated poll does not create history")
        require(repeated.sessionID == first.sessionID, "repeated poll keeps the session ID")
        require(repeated.readyToCapture, "an unattempted session remains ready")

        let snapshot = policy.snapshot
        require(snapshot.enabled, "the default policy is enabled")
        require(snapshot.isPlaying, "snapshot reports active playback")
        require(snapshot.candidateKey == "song-a", "snapshot reports the active key")
        require(snapshot.startDate == start, "snapshot reports the session start")
    }

    private static func verifyPauseResumeAndTrackChange() {
        let start = Date(timeIntervalSince1970: 2_000)
        var policy = AutomaticListeningPolicy()
        let first = policy.update(candidateKey: "song-a", isPlaying: true, now: start)
        guard let firstID = first.sessionID else { fail("first session ID missing") }

        let paused = policy.update(candidateKey: "song-a", isPlaying: false, now: start.addingTimeInterval(1))
        require(!paused.newSession, "pause does not create a replacement session")
        require(!paused.readyToCapture, "paused playback is not ready to capture")
        require(paused.endedSessionID == firstID, "pause ends the old session")
        require(paused.endReason == .notPlaying, "pause has a not-playing end reason")

        let resumed = policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(2))
        require(resumed.newSession, "resume creates a fresh continuous segment")
        require(resumed.shouldCreateHistory, "resume creates one history event for the new segment")
        require(resumed.sessionID != firstID, "resume uses a new session ID")

        let changed = policy.update(candidateKey: "song-b", isPlaying: true, now: start.addingTimeInterval(3))
        require(changed.newSession, "a playing track change creates a new session")
        require(changed.shouldCreateHistory, "a changed track creates one history event")
        require(changed.endedSessionID == resumed.sessionID, "track change ends the old session")
        require(changed.endedCandidateKey == "song-a", "track change reports the old key")
        require(changed.endReason == .trackChanged, "track change has the correct end reason")
        require(changed.candidateKey == "song-b", "track change reports the new key")
    }

    private static func verifyDisableAndReenable() {
        let start = Date(timeIntervalSince1970: 2_500)
        var policy = AutomaticListeningPolicy()
        let first = policy.update(candidateKey: "song-a", isPlaying: true, now: start)
        require(first.sessionID != nil, "a session exists before disabling")

        let disabled = policy.setEnabled(false)
        require(!policy.enabled, "disabling turns the policy off")
        require(disabled.endedSessionID == first.sessionID, "disabling ends the active session")
        require(disabled.endReason == .disabled, "disabling reports an explicit reason")
        let whileDisabled = policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(1))
        require(whileDisabled.sessionID == nil, "disabled policy never starts a session")
        require(!whileDisabled.readyToCapture, "disabled policy is never ready")

        let enabled = policy.setEnabled(true)
        require(policy.enabled, "re-enabling turns the policy on")
        require(enabled.sessionID == nil, "re-enabling waits for a fresh player update")
        let afterReenable = policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(2))
        require(afterReenable.newSession, "re-enabling creates a fresh session on the next update")
        require(afterReenable.sessionID != first.sessionID, "re-enabling does not reuse the old session")
        require(afterReenable.shouldCreateHistory, "re-enabling creates one fresh history event")
    }

    private static func verifyAttemptOnlyOnce() {
        let start = Date(timeIntervalSince1970: 3_000)
        var policy = AutomaticListeningPolicy()
        let first = policy.update(candidateKey: "song-a", isPlaying: true, now: start)
        require(policy.markCaptureAttempted(), "the first capture attempt is accepted")
        require(!policy.markCaptureAttempted(), "a second capture attempt is rejected")

        let afterAttempt = policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(10))
        require(afterAttempt.captureAttempted, "the session records the capture attempt")
        require(!afterAttempt.readyToCapture, "an attempted session is no longer ready")
        require(afterAttempt.sessionID == first.sessionID, "attempting does not replace the session")

        require(policy.allowCaptureRetry(), "an explicit retry reopens a failed attempt")
        let retry = policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(10.5))
        require(retry.readyToCapture, "an explicitly retried session is ready again")
        require(!retry.newSession, "retry keeps the same continuous segment")
        require(!retry.shouldCreateHistory, "retry does not create duplicate history")
        require(retry.sessionID == first.sessionID, "retry keeps the same session ID")
        require(policy.markCaptureAttempted(), "the retried segment accepts one new attempt")

        let paused = policy.update(candidateKey: "song-a", isPlaying: false, now: start.addingTimeInterval(11))
        require(paused.endedSessionID == first.sessionID, "attempted session can still be ended")
        require(!policy.markCaptureAttempted(), "there is no second attempt without a new segment")
    }

    private static func verifyStabilityDelayAndSeek() {
        let start = Date(timeIntervalSince1970: 4_000)
        var policy = AutomaticListeningPolicy(minimumStableDuration: 2)

        let first = policy.update(candidateKey: "song-a", isPlaying: true, now: start)
        require(first.newSession, "stability-delayed playback still creates a session")
        require(!first.readyToCapture, "a fresh identity is not ready before the delay")
        require(!policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(1.9)).readyToCapture, "identity remains unready before two seconds")
        require(policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(2)).readyToCapture, "identity becomes ready at the configured delay")

        let reset = policy.resetForDiscontinuity()
        require(reset.endedSessionID == first.sessionID, "seek reset ends the old session")
        require(reset.endReason == .discontinuity, "seek reset reports a discontinuity")
        require(policy.snapshot.sessionID == nil, "seek reset clears the active session")

        let afterSeek = policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(3))
        require(afterSeek.newSession, "seek allows a new segment")
        require(afterSeek.shouldCreateHistory, "the new segment gets one history event")
        require(afterSeek.sessionID != first.sessionID, "seek uses a new session ID")
        require(!afterSeek.readyToCapture, "the new segment observes the configured delay again")
    }

    private static func verifyUnknownAndStoppedPlayback() {
        let start = Date(timeIntervalSince1970: 5_000)
        var policy = AutomaticListeningPolicy()
        let first = policy.update(candidateKey: "song-a", isPlaying: true, now: start)

        let unknown = policy.update(candidateKey: nil, isPlaying: true, now: start.addingTimeInterval(1))
        require(unknown.endedSessionID == first.sessionID, "unknown identity ends the old session")
        require(unknown.endReason == .identityUnavailable, "unknown identity has an explicit reason")
        require(unknown.sessionID == nil, "unknown identity never starts a session")
        require(!unknown.readyToCapture, "unknown identity is never ready to capture")

        let stopped = policy.update(candidateKey: "song-a", isPlaying: false, now: start.addingTimeInterval(2))
        require(stopped.endedSessionID == nil, "stopping without a session is idempotent")
        require(policy.snapshot.sessionID == nil, "stopping leaves no active session")

        let restarted = policy.update(candidateKey: "song-a", isPlaying: true, now: start.addingTimeInterval(3))
        require(restarted.newSession, "known playback after unknown state starts a new session")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

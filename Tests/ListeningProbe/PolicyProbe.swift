import Foundation

@main
struct PolicyProbe {
    private static var checks = 0

    static func main() {
        verifyPreferenceDefaultsAndPersistence()
        verifyRepeatedPollingAndBoundaries()
        verifyExplicitRetry()
        verifyDisableDoesNotRestart()
        print("PASS: \(checks) automatic-listening policy checks")
    }

    private static func verifyPreferenceDefaultsAndPersistence() {
        let suiteName = "resonance-listening-policy-probe-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fail("could not create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)

        require(AutomaticListeningPreference.isEnabled(in: defaults), "missing preference defaults to enabled")
        require(defaults.object(forKey: AutomaticListeningPreference.key) == nil, "reading default does not write preference")

        AutomaticListeningPreference.setEnabled(false, in: defaults)
        require(!AutomaticListeningPreference.isEnabled(in: defaults), "disabled preference persists")
        AutomaticListeningPreference.setEnabled(true, in: defaults)
        require(AutomaticListeningPreference.isEnabled(in: defaults), "enabled preference persists")
    }

    private static func verifyRepeatedPollingAndBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000)
        var policy = AutomaticListeningPolicy()
        let first = policy.update(key: "song-a", isPlaying: true, now: start)
        guard let firstID = first.sessionID else { fail("first playing identity has no session") }
        require(first.readyToCapture, "a new session is ready to capture")

        let repeated = policy.update(key: "song-a", isPlaying: true, now: start.addingTimeInterval(1))
        require(repeated.sessionID == firstID, "repeated polling keeps one session")
        require(repeated.readyToCapture, "an unattempted session remains ready")

        let paused = policy.update(key: "song-a", isPlaying: false, now: start.addingTimeInterval(2))
        require(paused.sessionID == nil, "pause ends the session")
        require(!paused.readyToCapture, "paused playback is not ready")

        let resumed = policy.update(key: "song-a", isPlaying: true, now: start.addingTimeInterval(3))
        require(resumed.sessionID != nil && resumed.sessionID != firstID, "resume starts a fresh session")
        let changed = policy.update(key: "song-b", isPlaying: true, now: start.addingTimeInterval(4))
        require(changed.sessionID != resumed.sessionID, "track change starts a fresh session")

        policy.resetForDiscontinuity()
        let afterSeek = policy.update(key: "song-b", isPlaying: true, now: start.addingTimeInterval(5))
        require(afterSeek.sessionID != changed.sessionID, "discontinuity starts a fresh session")
    }

    private static func verifyExplicitRetry() {
        var policy = AutomaticListeningPolicy()
        let first = policy.update(key: "song-a", isPlaying: true)
        guard let firstID = first.sessionID else { fail("retry session has no ID") }
        require(policy.markCaptureAttempted(), "the first capture attempt is accepted")
        require(!policy.markCaptureAttempted(), "polling cannot repeat a capture attempt")
        require(!policy.update(key: "song-a", isPlaying: true).readyToCapture, "attempted session is not ready")
        require(policy.allowCaptureRetry(), "an explicit retry reopens the session")

        let retry = policy.update(key: "song-a", isPlaying: true)
        require(retry.sessionID == firstID, "retry keeps the same session")
        require(retry.readyToCapture, "retried session is ready")
    }

    private static func verifyDisableDoesNotRestart() {
        var policy = AutomaticListeningPolicy()
        let first = policy.update(key: "song-a", isPlaying: true)
        guard let firstID = first.sessionID else { fail("disable test session has no ID") }
        policy.setEnabled(false)
        require(!policy.enabled, "disable turns the policy off")
        require(policy.update(key: "song-a", isPlaying: true).sessionID == nil, "disabled policy does not start a session")

        policy.setEnabled(true)
        let afterEnable = policy.update(key: "song-a", isPlaying: true)
        require(afterEnable.sessionID != nil && afterEnable.sessionID != firstID, "enable waits for a fresh session")
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

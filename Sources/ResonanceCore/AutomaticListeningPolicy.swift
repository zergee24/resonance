import Foundation

/// Tracks one automatic-listening segment for a known playing identity.
///
/// The policy only owns the small amount of state needed to prevent duplicate
/// sessions and repeated automatic capture starts. Audio capture, persistence,
/// and analysis remain app responsibilities.
public struct AutomaticListeningPolicy: Sendable {
    public struct Observation: Equatable, Sendable {
        public let sessionID: UUID?
        public let readyToCapture: Bool

        public init(sessionID: UUID?, readyToCapture: Bool) {
            self.sessionID = sessionID
            self.readyToCapture = readyToCapture
        }
    }

    private struct Session: Sendable {
        let id: UUID
        let key: String
        var captureAttempted: Bool
    }

    public private(set) var enabled: Bool
    private var session: Session?

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// Poll the current player state. The same playing key keeps its session
    /// ID; a pause, unknown key, or key change ends that session.
    public mutating func update(
        key: String?,
        isPlaying: Bool,
        now: Date = Date()
    ) -> Observation {
        _ = now
        guard enabled, isPlaying, let key = validKey(key) else {
            session = nil
            return observation
        }

        if session?.key != key {
            session = Session(id: UUID(), key: key, captureAttempted: false)
        }
        return observation
    }

    /// Enable or disable automatic listening. Changing the toggle starts the
    /// next enabled segment from a clean state.
    public mutating func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        session = nil
    }

    /// Ends the current segment after a seek or another timeline break.
    public mutating func resetForDiscontinuity() {
        session = nil
    }

    /// Records the one automatic start attempt allowed for a segment.
    @discardableResult
    public mutating func markCaptureAttempted() -> Bool {
        guard enabled, session != nil, session?.captureAttempted == false else {
            return false
        }
        session?.captureAttempted = true
        return true
    }

    /// Reopens the current segment only after an explicit user retry.
    @discardableResult
    public mutating func allowCaptureRetry() -> Bool {
        guard enabled, session != nil, session?.captureAttempted == true else {
            return false
        }
        session?.captureAttempted = false
        return true
    }

    private var observation: Observation {
        guard let session else { return Observation(sessionID: nil, readyToCapture: false) }
        return Observation(sessionID: session.id, readyToCapture: !session.captureAttempted)
    }

    private func validKey(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return key
    }
}

/// UserDefaults persistence for the automatic-listening toggle.
public enum AutomaticListeningPreference {
    public static let key = "automaticListeningEnabled"

    /// An absent key means enabled so upgrades keep the requested default.
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

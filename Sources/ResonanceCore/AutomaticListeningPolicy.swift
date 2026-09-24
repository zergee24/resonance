import Foundation

/// The reason an automatic listening segment stopped.
public enum AutomaticListeningEndReason: String, Equatable, Sendable {
    case notPlaying
    case identityUnavailable
    case trackChanged
    case disabled
    case discontinuity
}

/// A small, side-effect-free state machine for automatic listening.
///
/// The policy knows only about playback identity and state.  It deliberately
/// does not start audio capture, persist history, or infer whether a segment
/// is a complete recording.  The app owns those effects and can use the
/// session ID to stop an old segment before starting a new one.
public struct AutomaticListeningPolicy: Sendable {
    public static let defaultMinimumStableDuration: TimeInterval = 0

    public struct Observation: Equatable, Sendable {
        public let newSession: Bool
        public let readyToCapture: Bool
        public let sessionID: UUID?
        public let candidateKey: String?
        public let startDate: Date?
        public let shouldCreateHistory: Bool
        public let captureAttempted: Bool
        public let endedSessionID: UUID?
        public let endedCandidateKey: String?
        public let endReason: AutomaticListeningEndReason?

        public init(
            newSession: Bool,
            readyToCapture: Bool,
            sessionID: UUID?,
            candidateKey: String?,
            startDate: Date?,
            shouldCreateHistory: Bool,
            captureAttempted: Bool,
            endedSessionID: UUID?,
            endedCandidateKey: String?,
            endReason: AutomaticListeningEndReason?
        ) {
            self.newSession = newSession
            self.readyToCapture = readyToCapture
            self.sessionID = sessionID
            self.candidateKey = candidateKey
            self.startDate = startDate
            self.shouldCreateHistory = shouldCreateHistory
            self.captureAttempted = captureAttempted
            self.endedSessionID = endedSessionID
            self.endedCandidateKey = endedCandidateKey
            self.endReason = endReason
        }

        /// Alias useful to callers that name the value after the active
        /// session rather than after the incoming player candidate.
        public var key: String? { candidateKey }

        public var sessionStartedAt: Date? { startDate }
    }

    public struct Snapshot: Equatable, Sendable {
        public let enabled: Bool
        public let isPlaying: Bool
        public let candidateKey: String?
        public let sessionID: UUID?
        public let startDate: Date?
        public let captureAttempted: Bool

        public init(
            enabled: Bool,
            isPlaying: Bool,
            candidateKey: String?,
            sessionID: UUID?,
            startDate: Date?,
            captureAttempted: Bool
        ) {
            self.enabled = enabled
            self.isPlaying = isPlaying
            self.candidateKey = candidateKey
            self.sessionID = sessionID
            self.startDate = startDate
            self.captureAttempted = captureAttempted
        }

        public var key: String? { candidateKey }

        public var sessionStartedAt: Date? { startDate }
    }

    private struct Session: Sendable {
        let id: UUID
        let key: String
        let startDate: Date
        var captureAttempted: Bool
    }

    public private(set) var enabled: Bool
    public let minimumStableDuration: TimeInterval

    private var session: Session?

    public init(
        enabled: Bool = true,
        minimumStableDuration: TimeInterval = AutomaticListeningPolicy.defaultMinimumStableDuration
    ) {
        self.enabled = enabled
        if minimumStableDuration.isFinite, minimumStableDuration >= 0 {
            self.minimumStableDuration = minimumStableDuration
        } else {
            self.minimumStableDuration = AutomaticListeningPolicy.defaultMinimumStableDuration
        }
    }

    /// Returns the current segment state without advancing it.
    public var snapshot: Snapshot {
        guard let session else {
            return Snapshot(
                enabled: enabled,
                isPlaying: false,
                candidateKey: nil,
                sessionID: nil,
                startDate: nil,
                captureAttempted: false
            )
        }
        return Snapshot(
            enabled: enabled,
            isPlaying: true,
            candidateKey: session.key,
            sessionID: session.id,
            startDate: session.startDate,
            captureAttempted: session.captureAttempted
        )
    }

    /// Advances the policy using one player observation.
    ///
    /// A session exists only while a known identity is playing.  Polling the
    /// same identity returns the same session ID and does not create another
    /// history event.  A pause, stop, unknown identity, track change, or
    /// discontinuity ends the old session; the next known playing update then
    /// starts a fresh segment.
    public mutating func update(
        candidateKey: String?,
        isPlaying: Bool,
        now: Date = Date()
    ) -> Observation {
        var endedSession: Session?
        var endReason: AutomaticListeningEndReason?

        guard enabled else {
            return observation(
                newSession: false,
                shouldCreateHistory: false,
                endedSession: nil,
                endReason: nil,
                now: now
            )
        }

        guard isPlaying, let key = validKey(candidateKey) else {
            if let current = session {
                endedSession = current
                session = nil
                endReason = isPlaying ? .identityUnavailable : .notPlaying
            }
            return observation(
                newSession: false,
                shouldCreateHistory: false,
                endedSession: endedSession,
                endReason: endReason,
                now: now
            )
        }

        if let current = session, current.key != key {
            endedSession = current
            session = nil
            endReason = .trackChanged
        }

        var created = false
        if session == nil {
            session = Session(id: UUID(), key: key, startDate: now, captureAttempted: false)
            created = true
        }

        return observation(
            newSession: created,
            shouldCreateHistory: created,
            endedSession: endedSession,
            endReason: endReason,
            now: now
        )
    }

    /// Equivalent spelling for callers that use `key` as their player model
    /// field name.
    public mutating func update(
        key: String?,
        isPlaying: Bool,
        now: Date = Date()
    ) -> Observation {
        update(candidateKey: key, isPlaying: isPlaying, now: now)
    }

    /// Marks the current session's one permitted automatic start attempt.
    /// Returns `true` only when this call changed the state.
    @discardableResult
    public mutating func markCaptureAttempted() -> Bool {
        guard enabled, session != nil, session?.captureAttempted == false else {
            return false
        }
        session?.captureAttempted = true
        return true
    }

    /// Allows an explicit user retry after a failed capture start.  This does
    /// not create a new segment or history event; automatic polling still
    /// remains one-attempt-only until the caller asks for this retry.
    @discardableResult
    public mutating func allowCaptureRetry() -> Bool {
        guard enabled, session != nil, session?.captureAttempted == true else {
            return false
        }
        session?.captureAttempted = false
        return true
    }

    /// Enables or disables automatic listening.  Disabling always ends the
    /// current segment and clears all state; re-enabling starts from a clean
    /// slate and waits for the next known playing identity.
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool) -> Observation {
        guard self.enabled != enabled else {
            return observation(
                newSession: false,
                shouldCreateHistory: false,
                endedSession: nil,
                endReason: nil,
                now: Date()
            )
        }

        let endedSession = session
        self.enabled = enabled
        session = nil
        return observation(
            newSession: false,
            shouldCreateHistory: false,
            endedSession: endedSession,
            endReason: endedSession == nil ? nil : (enabled ? .discontinuity : .disabled),
            now: endedSession?.startDate ?? Date()
        )
    }

    /// Ends the current segment after a seek or another known timeline break.
    /// The next playing update creates a new session, even when its identity
    /// is the same.
    @discardableResult
    public mutating func resetForDiscontinuity() -> Observation {
        let endedSession = session
        session = nil
        return observation(
            newSession: false,
            shouldCreateHistory: false,
            endedSession: endedSession,
            endReason: endedSession == nil ? nil : .discontinuity,
            now: endedSession?.startDate ?? Date()
        )
    }

    private func validKey(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return key
    }

    private func observation(
        newSession: Bool,
        shouldCreateHistory: Bool,
        endedSession: Session?,
        endReason: AutomaticListeningEndReason?,
        now: Date
    ) -> Observation {
        guard let current = session else {
            return Observation(
                newSession: false,
                readyToCapture: false,
                sessionID: nil,
                candidateKey: nil,
                startDate: nil,
                shouldCreateHistory: false,
                captureAttempted: false,
                endedSessionID: endedSession?.id,
                endedCandidateKey: endedSession?.key,
                endReason: endReason
            )
        }

        let elapsed = now.timeIntervalSince(current.startDate)
        let stable = elapsed.isFinite && elapsed >= minimumStableDuration
        return Observation(
            newSession: newSession,
            readyToCapture: stable && !current.captureAttempted,
            sessionID: current.id,
            candidateKey: current.key,
            startDate: current.startDate,
            shouldCreateHistory: shouldCreateHistory,
            captureAttempted: current.captureAttempted,
            endedSessionID: endedSession?.id,
            endedCandidateKey: endedSession?.key,
            endReason: endReason
        )
    }
}

/// UserDefaults persistence for the app's automatic-listening toggle.
///
/// An absent key deliberately means enabled, so an upgrade from an older
/// build starts with the requested default without writing a value back.
public enum AutomaticListeningPreference {
    public static let key = "automaticListeningEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

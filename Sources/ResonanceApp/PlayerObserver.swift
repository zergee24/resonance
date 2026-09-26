import AppKit
import ApplicationServices
import Combine
import Foundation
import ScreenCaptureKit
import Vision

/// The state that can be established from the native player's accessible UI.
///
/// `unknown` is deliberate.  The observer does not infer playback from a
/// missing control, and does not turn an unavailable value into a default.
public enum PlayerPlaybackState: String, Equatable, Codable {
    case playing
    case paused
    case stopped
    case unknown
}

public enum PlayerIdentityEvidence: String, Equatable, Codable {
    case platformID
    case platformURL
    case candidate
    case unavailable
}

public enum PlayerMetadataSource: String, Equatable, Codable {
    case systemPlayer, accessibility, screenOCR

    public var label: String {
        switch self {
        case .systemPlayer: return "系统播放信息"
        case .accessibility: return "辅助功能"
        case .screenOCR: return "窗口识别"
        }
    }
}

/// A read-only snapshot from the system player, with native UI fallbacks.
///
/// A snapshot without `trackID` and `trackURL` is a candidate only.  The
/// observer never creates an ID from a title, artist, duration, or an
/// accessibility identifier.
public struct PlayerSnapshot: Equatable {
    public let trackID: String?
    public let trackURL: URL?
    public let title: String?
    public let artist: String?
    public let album: String?
    public let currentTime: TimeInterval?
    public let duration: TimeInterval?
    public let playbackState: PlayerPlaybackState
    public let identityEvidence: PlayerIdentityEvidence
    public let limitations: [String]
    public let observedAt: Date
    public let metadataSource: PlayerMetadataSource
    public let sourceBundleIdentifier: String?
    public let sourceApplicationName: String?
    public let sourceProcessIdentifier: Int32?
    /// Opaque system identity, never a NetEase song ID.
    public let systemItemIdentifier: String?

    public init(
        trackID: String?,
        trackURL: URL?,
        title: String?,
        artist: String?,
        album: String?,
        currentTime: TimeInterval?,
        duration: TimeInterval?,
        playbackState: PlayerPlaybackState,
        identityEvidence: PlayerIdentityEvidence? = nil,
        limitations: [String] = [],
        observedAt: Date = Date(),
        metadataSource: PlayerMetadataSource = .accessibility,
        sourceBundleIdentifier: String? = nil,
        sourceApplicationName: String? = nil,
        sourceProcessIdentifier: Int32? = nil,
        systemItemIdentifier: String? = nil
    ) {
        self.trackID = trackID
        self.trackURL = trackURL
        self.title = title
        self.artist = artist
        self.album = album
        self.currentTime = currentTime
        self.duration = duration
        self.playbackState = playbackState
        self.identityEvidence = identityEvidence ?? PlayerSnapshot.defaultIdentityEvidence(trackID: trackID, trackURL: trackURL)
        self.limitations = limitations
        self.observedAt = observedAt
        self.metadataSource = metadataSource
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceApplicationName = sourceApplicationName
        self.sourceProcessIdentifier = sourceProcessIdentifier
        self.systemItemIdentifier = systemItemIdentifier
    }

    /// True when the UI supplied only metadata and the track cannot yet be
    /// bound to a platform track.
    public var isCandidate: Bool {
        trackID == nil && trackURL == nil
    }

    public var hasLimitedMetadata: Bool {
        title == nil || artist == nil || duration == nil || currentTime == nil ||
            identityEvidence == .candidate || identityEvidence == .unavailable || !limitations.isEmpty
    }

    public var progress: Double? {
        guard let currentTime, let duration, duration > 0 else { return nil }
        return min(max(currentTime / duration, 0), 1)
    }

    public var id: String? { trackID }
    public var neteaseID: String? { trackID }
    public var url: URL? { trackURL }
    public var position: TimeInterval? { currentTime }

    /// Stable enough for UI lists while still making two unbound candidates
    /// with different metadata distinct.  It is not a platform identity.
    public var candidateKey: String {
        let source = "\(metadataSource.rawValue)|\(sourceBundleIdentifier ?? "")|\(sourceProcessIdentifier.map(String.init) ?? "")"
        if let trackID { return "\(source)|netease-id:\(trackID)" }
        if let trackURL { return "\(source)|netease-url:\(trackURL.absoluteString)" }
        if let systemItemIdentifier { return "\(source)|system-item:\(systemItemIdentifier)" }
        return "\(source)|candidate:\(title ?? "")|\(artist ?? "")|\(album ?? "")"
    }

    /// Source attribution must agree with the process whose PCM will be tapped.
    public func matchesSource(bundleIdentifier: String?, processIdentifier: Int32) -> Bool {
        guard sourceBundleIdentifier != nil || sourceProcessIdentifier != nil else { return false }
        if let sourceBundleIdentifier, sourceBundleIdentifier != bundleIdentifier { return false }
        if let sourceProcessIdentifier, sourceProcessIdentifier != processIdentifier { return false }
        return true
    }

    public static func == (lhs: PlayerSnapshot, rhs: PlayerSnapshot) -> Bool {
        lhs.trackID == rhs.trackID &&
            lhs.trackURL == rhs.trackURL &&
            lhs.title == rhs.title &&
            lhs.artist == rhs.artist &&
            lhs.album == rhs.album &&
            lhs.currentTime == rhs.currentTime &&
            lhs.duration == rhs.duration &&
            lhs.playbackState == rhs.playbackState &&
            lhs.identityEvidence == rhs.identityEvidence &&
            lhs.limitations == rhs.limitations &&
            lhs.metadataSource == rhs.metadataSource &&
            lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier &&
            lhs.sourceApplicationName == rhs.sourceApplicationName &&
            lhs.sourceProcessIdentifier == rhs.sourceProcessIdentifier &&
            lhs.systemItemIdentifier == rhs.systemItemIdentifier
    }

    private static func defaultIdentityEvidence(trackID: String?, trackURL: URL?) -> PlayerIdentityEvidence {
        if trackID != nil { return .platformID }
        if trackURL != nil { return .platformURL }
        return .candidate
    }
}

public enum PlayerObserverStatus: Equatable {
    case idle
    case playerNotRunning
    case needsAccessibility
    case needsScreenCapture
    case observing
    case limitedMetadata(reason: String)

    public var message: String {
        switch self {
        case .idle:
            return "未开始监听"
        case .playerNotRunning:
            return "网易云音乐未运行"
        case .needsAccessibility:
            return "需要在系统设置中允许辅助功能访问"
        case .needsScreenCapture:
            return "屏幕读取备选需要在系统设置中允许屏幕录制"
        case .observing:
            return "已读取当前播放信息"
        case let .limitedMetadata(reason):
            return reason
        }
    }
}

public enum PlayerObserverEvent: Equatable {
    /// The player snapshot became unavailable (for example, the player
    /// exited, its process changed, or accessibility access was lost).
    case unavailable
    case trackChanged(PlayerSnapshot)
    case playbackStateChanged(PlayerPlaybackState)
    case positionChanged(currentTime: TimeInterval?, duration: TimeInterval?)
    case metadataUpdated(PlayerSnapshot)
}

/// Reads macOS Now Playing first. Accessibility and explicitly enabled OCR
/// remain fallbacks when the system service has no current track.
@MainActor
public final class PlayerObserver: ObservableObject {
    public nonisolated static let defaultBundleIdentifiers = [
        "com.netease.163music",
        "com.netease.cloudmusic",
        "com.netease.163music.desktop"
    ]

    @Published public private(set) var systemPlayerIssue: String?
    @Published public private(set) var snapshot: PlayerSnapshot?
    @Published public private(set) var permissionNeeded = false
    @Published public private(set) var screenCapturePermissionNeeded = false
    @Published public private(set) var screenCaptureFallbackEnabled = false
    @Published public private(set) var status: PlayerObserverStatus = .idle
    @Published public private(set) var lastEvent: PlayerObserverEvent?

    /// Called on the main actor after a meaningful accessible-UI change.
    public var eventHandler: ((PlayerObserverEvent) -> Void)?

    /// Recording remains scoped to NetEase, even when another system player
    /// owns Now Playing. Validate both supplied source identifiers against it.
    public var processIdentifier: pid_t? {
        guard let application = locatePlayer() else { return nil }
        if let snapshot, snapshot.metadataSource == .systemPlayer {
            guard snapshot.matchesSource(bundleIdentifier: application.bundleIdentifier,
                                         processIdentifier: application.processIdentifier) else { return nil }
        }
        return application.processIdentifier
    }

    public var canCaptureCurrentSource: Bool { processIdentifier != nil }

    private let systemReader: SystemPlayerReader
    private var systemPlayerTask: Task<Void, Never>?
    private var systemSnapshot: PlayerSnapshot?
    private var didReadSystemPlayer = false
    private var observationGeneration = UUID()

    private let bundleIdentifiers: [String]
    private let pollingInterval: TimeInterval
    private var timer: Timer?
    private var screenCaptureTask: Task<Void, Never>?
    private var isObserving = false
    private var lastProcessIdentifier: pid_t?
    private var pendingOCRKey: String?
    private var pendingOCRObservedAt: Date?
    private static let screenCaptureFallbackPreferenceKey = "resonance.screenCaptureFallbackEnabled"

    public init(
        bundleIdentifiers: [String] = PlayerObserver.defaultBundleIdentifiers,
        pollingInterval: TimeInterval = 0.6,
        systemReader: SystemPlayerReader = SystemPlayerReader()
    ) {
        self.systemReader = systemReader
        self.bundleIdentifiers = bundleIdentifiers
        self.pollingInterval = max(0.2, pollingInterval)
    }

    deinit {
        timer?.invalidate()
        systemPlayerTask?.cancel()
        systemReader.cancel()
        screenCaptureTask?.cancel()
    }

    public func start() {
        guard !isObserving else {
            refresh()
            return
        }

        isObserving = true
        didReadSystemPlayer = false
        observationGeneration = UUID()
        startSystemPlayerLoop()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }

    public func stop() {
        pendingOCRKey = nil
        pendingOCRObservedAt = nil
        isObserving = false
        observationGeneration = UUID()
        systemPlayerTask?.cancel()
        systemPlayerTask = nil
        systemReader.cancel()
        systemSnapshot = nil
        systemPlayerIssue = nil
        didReadSystemPlayer = false
        timer?.invalidate()
        timer = nil
        screenCaptureTask?.cancel()
        screenCaptureTask = nil
        screenCaptureFallbackEnabled = false
        screenCapturePermissionNeeded = false
        lastProcessIdentifier = nil
        publishSnapshot(nil)
        permissionNeeded = false
        status = .idle
    }

    /// Performs one read even when polling has not been started.  It never
    /// sends an action to 网易云音乐.
    @discardableResult
    public func refresh() -> PlayerSnapshot? {
        if let systemSnapshot, Date().timeIntervalSince(systemSnapshot.observedAt) <= 3 {
            permissionNeeded = false
            screenCapturePermissionNeeded = false
            screenCaptureTask?.cancel()
            screenCaptureTask = nil
            pendingOCRKey = nil
            pendingOCRObservedAt = nil
            publishSnapshot(systemSnapshot)
            status = .observing
            return systemSnapshot
        }
        // Wait for the first system query before asking for fallback permissions.
        guard !isObserving || didReadSystemPlayer else { return snapshot }
        systemSnapshot = nil
        if snapshot?.metadataSource == .systemPlayer { publishSnapshot(nil) }
        restoreScreenCaptureFallbackIfPermitted()
        guard let application = locatePlayer() else {
            pendingOCRKey = nil
            pendingOCRObservedAt = nil
            lastProcessIdentifier = nil
            publishSnapshot(nil)
            permissionNeeded = false
            status = .playerNotRunning
            return nil
        }

        if let previousProcessIdentifier = lastProcessIdentifier,
           previousProcessIdentifier != application.processIdentifier {
            pendingOCRKey = nil
            pendingOCRObservedAt = nil
            publishSnapshot(nil)
        }
        lastProcessIdentifier = application.processIdentifier

        guard AXIsProcessTrusted() else {
            permissionNeeded = true
            if screenCaptureFallbackEnabled {
                if screenCapturePermissionNeeded {
                    status = .needsScreenCapture
                } else if snapshot == nil {
                    status = .limitedMetadata(reason: "辅助功能尚未授权；正在等待屏幕读取候选曲目")
                }
                // Screen capture is an independent, explicit fallback.  Do
                // not make it depend on AX permission being granted.
                return snapshot
            }
            publishSnapshot(nil)
            status = .needsAccessibility
            return nil
        }

        permissionNeeded = false
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let nodes = collectNodes(from: applicationElement)
        let metadata = parse(nodes, applicationElement: applicationElement)

        guard metadata.hasEvidence else {
            // Once the explicit OCR fallback has produced a candidate, an
            // empty AX tree must not erase it on every polling tick.  The
            // next OCR pass will replace it when the player changes track.
            if screenCaptureFallbackEnabled, snapshot != nil {
                if screenCapturePermissionNeeded {
                    status = .needsScreenCapture
                }
                return snapshot
            }
            publishSnapshot(nil)
            status = screenCaptureFallbackEnabled && screenCapturePermissionNeeded
                ? .needsScreenCapture
                : .limitedMetadata(reason: "系统未提供当前歌曲；网易云当前页面也未暴露辅助功能元数据")
            return nil
        }

        let next = PlayerSnapshot(
            trackID: metadata.trackID,
            trackURL: metadata.trackURL,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            currentTime: metadata.currentTime,
            duration: metadata.duration,
            playbackState: metadata.playbackState,
            identityEvidence: metadata.identityEvidence,
            limitations: metadata.limitations,
            metadataSource: .accessibility,
            sourceBundleIdentifier: application.bundleIdentifier,
            sourceApplicationName: application.localizedName,
            sourceProcessIdentifier: application.processIdentifier
        )
        publishSnapshot(next)

        let limitations = metadata.limitations
        status = screenCaptureFallbackEnabled && screenCapturePermissionNeeded
            ? .needsScreenCapture
            : limitations.isEmpty
            ? .observing
            : .limitedMetadata(reason: limitations.joined(separator: "；"))
        return next
    }

    private func startSystemPlayerLoop() {
        let generation = observationGeneration
        systemPlayerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var state: SystemPlayerState?
                var issue: String?
                do { state = try await self.systemReader.read() }
                catch { issue = error.localizedDescription }
                guard !Task.isCancelled, self.isObserving,
                      self.observationGeneration == generation else { return }
                self.systemPlayerIssue = issue
                self.didReadSystemPlayer = true
                // A single failed query may reuse the last successful sample
                // only within the same three-second freshness window.
                if let state { self.systemSnapshot = self.makeSystemSnapshot(state) }
                else if issue == nil { self.systemSnapshot = nil }
                self.refresh()
                do { try await Task.sleep(nanoseconds: 800_000_000) }
                catch { return }
            }
        }
    }

    private func makeSystemSnapshot(_ state: SystemPlayerState) -> PlayerSnapshot {
        let application = state.processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? state.bundleIdentifier.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
            }
        return PlayerSnapshot(
            trackID: nil, trackURL: nil, title: state.title, artist: state.artist, album: state.album,
            currentTime: state.currentTime, duration: state.duration,
            playbackState: state.playing.map { $0 ? .playing : .paused } ?? .unknown,
            metadataSource: .systemPlayer,
            sourceBundleIdentifier: state.bundleIdentifier ?? application?.bundleIdentifier,
            sourceApplicationName: application?.localizedName ?? state.bundleIdentifier,
            sourceProcessIdentifier: state.processIdentifier ?? application?.processIdentifier,
            systemItemIdentifier: state.contentItemIdentifier
        )
    }

    /// Opens the system Accessibility settings prompt only when explicitly
    /// requested by the product UI.  `start()` and `refresh()` never surprise
    /// the user with a system prompt.
    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            permissionNeeded = false
            if isObserving { refresh() }
            return true
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        permissionNeeded = !trusted
        if trusted {
            if isObserving { refresh() }
        } else {
            status = .needsAccessibility
        }
        return trusted
    }

    /// Enables the optional, explicit screen-reading fallback.  It is off by
    /// default and never starts from `start()` or from the polling loop.  The
    /// fallback captures only the selected 网易云音乐 window, keeps the image
    /// in memory for one OCR pass, and emits candidate metadata only.
    @discardableResult
    public func enableScreenCaptureFallback() -> Bool {
        UserDefaults.standard.set(true, forKey: Self.screenCaptureFallbackPreferenceKey)
        screenCaptureFallbackEnabled = true
        if systemSnapshot != nil { return true }

        guard CGPreflightScreenCaptureAccess() else {
            screenCapturePermissionNeeded = true
            let granted = CGRequestScreenCaptureAccess()
            screenCapturePermissionNeeded = !granted
            if granted {
                startScreenCaptureLoop()
            } else if snapshot == nil {
                status = .needsScreenCapture
            }
            return granted
        }

        screenCapturePermissionNeeded = false
        startScreenCaptureLoop()
        return true
    }

    public func disableScreenCaptureFallback() {
        pendingOCRKey = nil
        pendingOCRObservedAt = nil
        UserDefaults.standard.set(false, forKey: Self.screenCaptureFallbackPreferenceKey)
        screenCaptureFallbackEnabled = false
        screenCapturePermissionNeeded = false
        screenCaptureTask?.cancel()
        screenCaptureTask = nil
        if isObserving { refresh() }
    }

    // MARK: User initiated controls

    /// Presses the native play control.  This method is never called by the
    /// polling loop; callers should invoke it only after a user action.
    @discardableResult
    public func play() -> Bool {
        performPlaybackAction(.play)
    }

    /// Presses the native pause control.  This method is never called by the
    /// polling loop; callers should invoke it only after a user action.
    @discardableResult
    public func pause() -> Bool {
        performPlaybackAction(.pause)
    }

    /// Toggles only when the current state is known.  An unknown state is not
    /// guessed because an accidental press changes the user's playback.
    @discardableResult
    public func togglePlayPause() -> Bool {
        guard let playbackState = snapshot?.playbackState else { return false }
        switch playbackState {
        case .playing:
            return performPlaybackAction(.pause)
        case .paused, .stopped:
            return performPlaybackAction(.play)
        case .unknown:
            return false
        }
    }

    /// Opens a URL supplied by the accessible UI.  No URL is generated from a
    /// candidate title or artist.
    @discardableResult
    public func openTrack(url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// Opens the exact link exposed by the player.  If only an exact ID was
    /// exposed, the public NetEase song URL is a deterministic representation
    /// of that ID; a candidate without either value cannot be opened.
    @discardableResult
    public func openCurrentTrack() -> Bool {
        guard let current = snapshot else { return false }
        let url = current.trackURL ?? current.trackID.flatMap { URL(string: "https://music.163.com/song?id=\($0)") }
        guard let url else { return false }
        return openTrack(url: url)
    }

    // MARK: Accessibility tree

    private struct AXNode {
        let element: AXUIElement
        let role: String
        let subrole: String
        let title: String?
        let description: String?
        let value: Any?
        let identifier: String?
        let url: URL?
        let minValue: Double?
        let maxValue: Double?

        var text: String {
            [title, description, stringValue(value), identifier]
                .compactMap { $0 }
                .map(Self.normalize)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private static func normalize(_ text: String) -> String {
            text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct ParsedMetadata {
        var trackID: String?
        var trackURL: URL?
        var identityEvidence = PlayerIdentityEvidence.unavailable
        var title: String?
        var artist: String?
        var album: String?
        var currentTime: TimeInterval?
        var duration: TimeInterval?
        var playbackState = PlayerPlaybackState.unknown
        var hasEvidence = false
        var limitations: [String] = []
    }

    private enum PlaybackAction {
        case play
        case pause
    }

    private func locatePlayer() -> NSRunningApplication? {
        for bundleIdentifier in bundleIdentifiers {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if let application = applications.first(where: { !$0.isTerminated }) {
                return application
            }
        }

        // Some signed builds have changed their bundle identifier.  The
        // fallback remains an NSRunningApplication/PID lookup and is limited
        // to the player's visible process names.
        let names = Set(["网易云音乐", "NetEase Cloud Music", "Netease Cloud Music"])
        return NSWorkspace.shared.runningApplications.first {
            guard !$0.isTerminated, let name = $0.localizedName else { return false }
            return names.contains(name)
        }
    }

    private func collectNodes(from application: AXUIElement) -> [AXNode] {
        var result: [AXNode] = []
        var visited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 12, visited < 700 else { return }
            visited += 1

            let node = AXNode(
                element: element,
                role: stringValue(copyAttribute(element, "AXRole")) ?? "",
                subrole: stringValue(copyAttribute(element, "AXSubrole")) ?? "",
                title: stringValue(copyAttribute(element, "AXTitle")),
                description: stringValue(copyAttribute(element, "AXDescription")),
                value: copyAttribute(element, "AXValue"),
                identifier: stringValue(copyAttribute(element, "AXIdentifier")),
                url: exposedURL(for: element),
                minValue: numberValue(copyAttribute(element, "AXMinValue")),
                maxValue: numberValue(copyAttribute(element, "AXMaxValue"))
            )
            result.append(node)

            for child in children(of: element) {
                visit(child, depth: depth + 1)
            }
        }

        visit(application, depth: 0)
        return result
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, "AXChildren") else { return [] }
        if let children = value as? [AXUIElement] { return children }
        if let children = value as? NSArray {
            return children.map { $0 as! AXUIElement }
        }
        return []
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success, let value else { return nil }
        return value
    }

    private func exposedURL(for element: AXUIElement) -> URL? {
        for key in ["AXURL", "AXLinkURL"] {
            if let url = urlValue(copyAttribute(element, key)), isTrackURL(url) {
                return url
            }
        }
        return nil
    }

    private func parse(_ nodes: [AXNode], applicationElement: AXUIElement) -> ParsedMetadata {
        var metadata = ParsedMetadata()

        let urlNodes = nodes.filter { $0.url != nil }
        if let urlNode = urlNodes.first(where: { isTrackURL($0.url) }) {
            metadata.trackURL = urlNode.url
            metadata.trackID = trackID(from: urlNode.url)
            metadata.identityEvidence = metadata.trackID == nil ? .platformURL : .platformID
        }

        let textualCandidates = nodes.compactMap { trackTextCandidate(from: $0) }
        if let best = bestTrackCandidate(textualCandidates) {
            metadata.title = best.title
            metadata.artist = best.artist
            metadata.album = best.album
            if metadata.trackURL == nil, let url = best.url, isTrackURL(url) {
                metadata.trackURL = url
                metadata.trackID = trackID(from: url)
                metadata.identityEvidence = metadata.trackID == nil ? .platformURL : .platformID
            }
        }

        let times = timeReading(from: nodes)
        metadata.currentTime = times.currentTime
        metadata.duration = times.duration
        metadata.playbackState = playbackState(from: nodes)
        metadata.hasEvidence = metadata.title != nil || metadata.artist != nil ||
            metadata.trackID != nil || metadata.trackURL != nil ||
            metadata.currentTime != nil || metadata.duration != nil ||
            metadata.playbackState != .unknown

        if metadata.title == nil { metadata.limitations.append("缺少歌曲标题") }
        if metadata.artist == nil { metadata.limitations.append("缺少艺人信息") }
        if metadata.currentTime == nil || metadata.duration == nil {
            metadata.limitations.append("缺少标准播放进度或时长")
        }
        if metadata.trackID == nil && metadata.trackURL == nil {
            metadata.limitations.append("未暴露网易云歌曲 ID/链接，当前仅为候选曲目")
            metadata.identityEvidence = metadata.hasEvidence ? .candidate : .unavailable
        }
        if metadata.playbackState == .unknown {
            metadata.limitations.append("缺少可识别的播放状态")
        }

        // Read standard diagnostics when available, but never write these
        // attributes.  A web-rendered page may expose an empty tree even when
        // the application itself is trusted; that remains a real limitation.
        _ = copyAttribute(applicationElement, "AXEnhancedUserInterface")
        _ = copyAttribute(applicationElement, "AXManualAccessibility")

        return metadata
    }

    private struct TrackTextCandidate {
        let title: String?
        let artist: String?
        let album: String?
        let url: URL?
        let score: Int
        let raw: String
    }

    private func trackTextCandidate(from node: AXNode) -> TrackTextCandidate? {
        let rawPieces = [node.title, node.description, stringValue(node.value)]
            .compactMap { $0 }
            .map(normalize)
            .filter { !$0.isEmpty }
        guard !rawPieces.isEmpty else { return nil }

        let raw = rawPieces.joined(separator: " ")
        let lowered = raw.lowercased()
        if isNavigationText(lowered) { return nil }

        let trackText = stripNowPlayingContext(raw)
        let pair = parseTrackPair(trackText)
        let labelled = parseLabelledTrack(trackText)
        let contextual = containsNowPlayingContext(lowered)
        let exactURL = node.url.flatMap { isTrackURL($0) ? $0 : nil }

        // A lone generic control label such as “播放” is not a song name.
        guard pair != nil || labelled != nil || exactURL != nil ||
            (contextual && raw.count >= 2) else { return nil }

        var score = 0
        if pair != nil { score += 4 }
        if labelled != nil { score += 5 }
        if contextual { score += 7 }
        if exactURL != nil { score += 10 }
        if node.role == "AXStaticText" { score += 1 }
        if node.role == "AXButton" { score += 1 }

        let title = labelled?.title ?? pair?.title ?? (exactURL == nil ? trackText : nil)
        let artist = labelled?.artist ?? pair?.artist
        let album = labelled?.album
        return TrackTextCandidate(title: title, artist: artist, album: album, url: exactURL, score: score, raw: raw)
    }

    private func bestTrackCandidate(_ candidates: [TrackTextCandidate]) -> TrackTextCandidate? {
        guard !candidates.isEmpty else { return nil }
        let urlCandidate = candidates
            .filter { $0.url != nil }
            .max { $0.score < $1.score }
        if let urlCandidate { return urlCandidate }

        let contextual = candidates.filter { containsNowPlayingContext($0.raw.lowercased()) }
        if let bestContextual = contextual.max(by: { $0.score < $1.score }) {
            return bestContextual
        }

        // When the native UI presents exactly one track-shaped label, it is
        // safe to expose it as a candidate.  Multiple ambiguous song rows are
        // left unresolved rather than silently selecting a playlist row.
        if candidates.count == 1 { return candidates[0] }
        return nil
    }

    private func parseLabelledTrack(_ text: String) -> (title: String, artist: String?, album: String?)? {
        let pattern = #"(?i)(?:歌曲|歌名|track|title)\s*[:：]\s*(.+?)(?:\s+(?:艺人|歌手|artist)\s*[:：]\s*(.+?))?(?:\s+(?:专辑|album)\s*[:：]\s*(.+))?$"#
        guard let match = firstMatch(pattern: pattern, in: text) else { return nil }
        guard let titleValue = match[1] else { return nil }
        let title = titleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artist = match[2]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = match[3]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title: title, artist: artist, album: album)
    }

    private func parseTrackPair(_ text: String) -> (title: String, artist: String)? {
        let separators = [" - ", " — ", " – ", "｜", " | ", "\n"]
        for separator in separators {
            let pieces = text.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard pieces.count == 2 else { continue }
            guard pieces[0].count >= 1, pieces[1].count >= 1,
                  pieces[0].count <= 160, pieces[1].count <= 160 else { continue }
            if isNavigationText(pieces[0].lowercased()) || isNavigationText(pieces[1].lowercased()) { continue }
            return (title: pieces[0], artist: pieces[1])
        }
        return nil
    }

    private func timeReading(from nodes: [AXNode]) -> (currentTime: TimeInterval?, duration: TimeInterval?) {
        for node in nodes {
            let strings = [node.title, node.description, stringValue(node.value)]
                .compactMap { $0 }
                .map(normalize)
            for string in strings {
                if let pair = parseTimePair(string) {
                    return pair
                }
            }
        }

        // A labelled AXSlider is the only safe scalar representation.  Do
        // not treat an unlabelled volume slider as playback progress.
        for node in nodes where node.role == "AXSlider" {
            guard let current = numberValue(node.value), let maximum = node.maxValue,
                  maximum > 5, current >= 0, current <= maximum else { continue }
            let label = node.text.lowercased()
            guard label.contains("进度") || label.contains("播放") ||
                label.contains("progress") || label.contains("position") ||
                label.contains("time") else { continue }
            return (currentTime: current, duration: maximum)
        }
        return (nil, nil)
    }

    private func parseTimePair(_ text: String) -> (currentTime: TimeInterval, duration: TimeInterval)? {
        let pattern = #"^\s*(\d{1,3}:\d{2}(?::\d{2})?)\s*(?:/|／|of)\s*(\d{1,3}:\d{2}(?::\d{2})?)\s*$"#
        guard let match = firstMatch(pattern: pattern, in: text),
              let current = parseClock(match[1]),
              let duration = parseClock(match[2]),
              duration > 0, current >= 0, current <= duration else { return nil }
        return (currentTime: current, duration: duration)
    }

    private func playbackState(from nodes: [AXNode]) -> PlayerPlaybackState {
        let controls = nodes.filter { $0.role == "AXButton" || $0.role == "AXToggleButton" }
        let pauseControls = controls.filter { node in
            let label = node.text.lowercased()
            return label.contains("暂停") || hasStandaloneWord("pause", in: label)
        }
        if pauseControls.contains(where: isTransportControl) { return .playing }
        if pauseControls.count == 1 { return .playing }

        let playControls = controls.filter { isPlayLabel($0.text.lowercased()) }
        if playControls.first(where: isTransportControl) != nil { return .paused }
        return playControls.count == 1 ? .paused : .unknown
    }

    private func isPlayLabel(_ label: String) -> Bool {
        guard label.contains("播放") || hasStandaloneWord("play", in: label) ||
            hasStandaloneWord("resume", in: label) else { return false }
        return !label.contains("播放列表") && !label.contains("播放全部") &&
            !label.contains("播放歌单") && !label.contains("播放所有")
    }

    private func performPlaybackAction(_ action: PlaybackAction) -> Bool {
        guard AXIsProcessTrusted(), let application = locatePlayer() else { return false }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        let nodes = collectNodes(from: root)
        let candidates = nodes.filter { node in
            guard node.role == "AXButton" || node.role == "AXToggleButton" else { return false }
            let label = node.text.lowercased()
            switch action {
            case .play:
                return isPlayLabel(label)
            case .pause:
                return label.contains("暂停") || hasStandaloneWord("pause", in: label)
            }
        }
        guard !candidates.isEmpty else { return false }
        let control = candidates.first(where: isTransportControl) ?? (candidates.count == 1 ? candidates[0] : nil)
        guard let control else { return false }

        return AXUIElementPerformAction(control.element, kAXPressAction as CFString) == .success
    }

    private func isTransportControl(_ node: AXNode) -> Bool {
        let context = [node.title, node.description, node.identifier]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return containsNowPlayingContext(context) || context.contains("播放控制") ||
            context.contains("transport") || context.contains("player-control") ||
            context.contains("mini-player")
    }

    // MARK: Explicit screen-reading fallback

    private struct OCRMetadata {
        let title: String?
        let artist: String?
        let currentTime: TimeInterval?
        let duration: TimeInterval?
        let playbackState: PlayerPlaybackState
        let hasEvidence: Bool
    }

    private struct OCRLine {
        let text: String
        let minX: CGFloat
        let maxX: CGFloat
        let y: CGFloat

        var midX: CGFloat { (minX + maxX) / 2 }
    }

    private func restoreScreenCaptureFallbackIfPermitted() {
        guard UserDefaults.standard.bool(forKey: Self.screenCaptureFallbackPreferenceKey),
              CGPreflightScreenCaptureAccess() else { return }
        screenCaptureFallbackEnabled = true
        screenCapturePermissionNeeded = false
        startScreenCaptureLoop()
    }

    private func startScreenCaptureLoop() {
        guard screenCaptureTask == nil, systemSnapshot == nil else { return }
        screenCaptureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.captureOCROnce()
                do {
                    try await Task.sleep(nanoseconds: 900_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func captureOCROnce() async {
        guard systemSnapshot == nil, screenCaptureFallbackEnabled,
              !screenCapturePermissionNeeded,
              let application = locatePlayer() else { return }

        guard CGPreflightScreenCaptureAccess() else {
            screenCapturePermissionNeeded = true
            if snapshot == nil { status = .needsScreenCapture }
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows
                .filter({ $0.owningApplication?.processID == application.processIdentifier })
                .sorted(by: { lhs, rhs in
                    if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen && !rhs.isOnScreen }
                    return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
                })
                .first else {
                updateScreenCaptureLimitation("未找到网易云可捕获窗口")
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = max(CGFloat(filter.pointPixelScale), 1)
            let configuration = SCStreamConfiguration()
            configuration.width = max(Int(window.frame.width * scale), 1)
            configuration.height = max(Int(window.frame.height * scale), 1)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard !Task.isCancelled, systemSnapshot == nil else { return }
            guard let bottomBar = cropBottomBar(from: image, scale: scale) else {
                updateScreenCaptureLimitation("网易云窗口没有可读取的底部播放区域")
                return
            }

            let ocr = recognizeBottomBar(bottomBar, scale: scale)
            guard ocr.hasEvidence else {
                pendingOCRKey = nil
                pendingOCRObservedAt = nil
                updateScreenCaptureLimitation("屏幕读取未识别到网易云底部播放信息")
                return
            }
            guard systemSnapshot == nil, screenCaptureFallbackEnabled, !Task.isCancelled else { return }
            mergeOCR(ocr, transportState: exposedMenuPlaybackState(application))
        } catch {
            updateScreenCaptureLimitation("网易云窗口屏幕读取失败：\(error.localizedDescription)")
        }
    }

    private func cropBottomBar(from image: CGImage, scale: CGFloat = 1) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        // In the ScreenCaptureKit image used here y=0 was observed at the
        // window top. Keep only the lower playback bar; the previous
        // one-third crop also included song-list/search text.
        let height = min(image.height, max(Int(80 * scale), 1))
        let y = max(0, image.height - height)
        return image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height))
    }

    private func recognizeBottomBar(_ image: CGImage, scale: CGFloat = 1) -> OCRMetadata {
        // NetEase renders the red VIP badge beside the white song title. Vision
        // sometimes joins that badge into the title line (for example
        // "Trouble I'm In VIP"). Remove only saturated-red metadata pixels
        // before OCR; the title and artist pixels remain untouched.
        let ocrImage = suppressRedBadgePixels(from: image, scale: scale) ?? image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ja-JP", "zh-Hans", "en-US"]
        request.automaticallyDetectsLanguage = true

        let observations: [VNRecognizedTextObservation]
        do {
            let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
            try handler.perform([request])
            observations = request.results ?? []
        } catch {
            return OCRMetadata(title: nil, artist: nil, currentTime: nil, duration: nil, playbackState: .unknown, hasEvidence: false)
        }

        let lines = observations
            .compactMap { observation -> OCRLine? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return OCRLine(text: normalize(text), minX: box.minX, maxX: box.maxX, y: box.midY)
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.y > $1.y }

        let times = lines.flatMap { clockValues(in: $0.text) }
        let currentTime = times.count >= 2 ? times[0] : nil
        let duration = times.count >= 2 ? times[1] : nil
        let playbackState = lines.filter { $0.minX > 0.35 && $0.maxX < 0.7 }
            .reduce(into: PlayerPlaybackState.unknown) { state, line in
            let lowered = line.text.lowercased()
            if lowered == "暂停" || lowered == "pause" {
                state = .playing
            } else if ["播放", "play", "resume"].contains(lowered), state == .unknown {
                state = .paused
            }
        }

        let textLines = lines.filter {
            !containsClock($0.text) && !isOCRControlLabel($0.text) &&
                $0.minX * CGFloat(image.width) >= 80 * scale && $0.minX < 0.45
        }
        // Title and artist share the left metadata origin. The horizontal
        // tolerance keeps long Japanese titles while excluding right-side
        // like counts, quality labels, and transport controls.
        let leftAnchor = textLines.map(\.minX).min() ?? 0
        let leftAlignedLines = textLines.filter {
            ($0.minX - leftAnchor) * CGFloat(image.width) <= 12 * scale
        }
        let pair = leftAlignedLines.lazy.compactMap { self.parseTrackPair($0.text) }.first
        let title = pair?.title ?? leftAlignedLines.first?.text
        let artist = pair?.artist ?? (leftAlignedLines.count > 1 ? leftAlignedLines[1].text : nil)
        let hasEvidence = title != nil || artist != nil || currentTime != nil || duration != nil || playbackState != .unknown
        return OCRMetadata(
            title: title,
            artist: artist,
            currentTime: currentTime,
            duration: duration,
            playbackState: playbackState,
            hasEvidence: hasEvidence
        )
    }

    /// Removes saturated-red pixels from the left metadata area. This is
    /// intentionally image evidence based: deleting a string such as "VIP"
    /// would corrupt real song titles containing that word.
    private func suppressRedBadgePixels(from image: CGImage, scale: CGFloat = 1) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let effectiveScale = max(scale, 1)
        let metadataStart = min(width, max(0, Int((80 * effectiveScale).rounded())))
        let metadataEnd = min(width, max(metadataStart, Int((CGFloat(width) * 0.45).rounded())))
        guard metadataStart < metadataEnd else { return image }
        for y in 0..<height {
            for x in metadataStart..<metadataEnd {
                let offset = (y * width + x) * 4
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                guard bytes[offset + 3] > 0,
                      red >= 150,
                      red >= green + 55,
                      red >= blue + 55 else { continue }
                // Transparent black is ignored by Vision and does not touch
                // adjacent white/gray title pixels.
                bytes[offset] = 0
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
                bytes[offset + 3] = 0
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func exposedMenuPlaybackState(_ application: NSRunningApplication) -> PlayerPlaybackState {
        guard AXIsProcessTrusted() else { return .unknown }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        guard let rawMenuBar = copyAttribute(root, "AXMenuBar") else { return .unknown }
        let menuBar = rawMenuBar as! AXUIElement
        guard let controlsMenu = children(of: menuBar).first(where: {
            ["控制", "Controls", "Control"].contains(stringValue(copyAttribute($0, "AXTitle")) ?? "")
        }) else { return .unknown }
        // Read the existing menu tree without opening or clicking it. The
        // toggle action names the action available now, not the current state.
        let labels = Set(collectNodes(from: controlsMenu).filter { $0.role == "AXMenuItem" }
            .compactMap(\.title).map { normalize($0).lowercased() })
        let canPause = !labels.isDisjoint(with: ["暂停", "pause"])
        let canPlay = !labels.isDisjoint(with: ["播放", "play", "resume"])
        if canPause && !canPlay { return .playing }
        if canPlay && !canPause { return .paused }
        return .unknown
    }

    private func mergeOCR(_ ocr: OCRMetadata, transportState: PlayerPlaybackState = .unknown) {
        guard systemSnapshot == nil else { return }
        let application = locatePlayer()
        // OCR is a candidate source only.  It cannot establish that the
        // current text belongs to the same platform track as the previous
        // snapshot, so do not carry over any identity or partially
        // recognised metadata from that snapshot.  In particular, retaining
        // an old ID/URL while the OCR title changes would bind a new song to
        // the old platform identity.
        let title = ocr.title
        let artist = ocr.artist
        let currentTime = ocr.currentTime
        let duration = ocr.duration
        let playbackState = transportState == .unknown ? ocr.playbackState : transportState
        var limitations: [String] = []
        appendUnique("屏幕 OCR 仅提供候选曲目元数据，不能证明精确歌曲 ID/链接", to: &limitations)
        appendUnique("OCR 不能证明整曲覆盖，需通过 PCM 采集状态判断", to: &limitations)
        if title == nil { appendUnique("OCR 未识别到歌曲标题", to: &limitations) }
        if artist == nil { appendUnique("OCR 未识别到艺人信息", to: &limitations) }
        if currentTime == nil || duration == nil {
            appendUnique("OCR 未识别到完整播放进度或时长", to: &limitations)
        }
        if playbackState == .unknown { appendUnique("尚未识别播放/暂停状态，可手动采集", to: &limitations) }

        let next = PlayerSnapshot(
            trackID: nil,
            trackURL: nil,
            title: title,
            artist: artist,
            album: nil,
            currentTime: currentTime,
            duration: duration,
            playbackState: playbackState,
            identityEvidence: .candidate,
            limitations: limitations,
            metadataSource: .screenOCR,
            sourceBundleIdentifier: application?.bundleIdentifier,
            sourceApplicationName: application?.localizedName,
            sourceProcessIdentifier: application?.processIdentifier
        )
        publishStableOCR(next)
        status = .limitedMetadata(reason: limitations.joined(separator: "；"))
    }

    private func publishStableOCR(_ next: PlayerSnapshot) {
        guard systemSnapshot == nil else { return }
        let previous = snapshot.flatMap { $0.identityEvidence == .candidate ? $0 : nil }
        let hasTitle = !(next.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let repeatsPending = hasTitle && pendingOCRKey == next.candidateKey &&
            pendingOCRObservedAt.map { next.observedAt.timeIntervalSince($0) <= 3 } == true
        if hasTitle && (previous?.candidateKey == next.candidateKey || repeatsPending) {
            pendingOCRKey = nil
            pendingOCRObservedAt = nil
            publishSnapshot(next)
            return
        }

        // A single OCR change can be a badge, animation, or recognition error.
        // Confirm it on the next read before creating a new recording segment.
        pendingOCRKey = hasTitle ? next.candidateKey : nil
        pendingOCRObservedAt = hasTitle ? next.observedAt : nil
        guard let previous else { return }
        // Transport state is independent of identity. Pause immediately while
        // preserving the old identity's timestamp so unstable text can expire.
        publishSnapshot(PlayerSnapshot(
            trackID: nil, trackURL: nil, title: previous.title,
            artist: previous.artist, album: previous.album,
            currentTime: nil, duration: previous.duration,
            playbackState: next.playbackState == .playing ? previous.playbackState : next.playbackState,
            identityEvidence: .candidate,
            limitations: previous.limitations, observedAt: previous.observedAt,
            metadataSource: previous.metadataSource,
            sourceBundleIdentifier: previous.sourceBundleIdentifier,
            sourceApplicationName: previous.sourceApplicationName,
            sourceProcessIdentifier: previous.sourceProcessIdentifier
        ))
    }

    private func updateScreenCaptureLimitation(_ reason: String) {
        guard screenCaptureFallbackEnabled, snapshot == nil else { return }
        status = .limitedMetadata(reason: reason)
    }

    private func clockValues(in text: String) -> [TimeInterval] {
        let pattern = #"\b\d{1,3}:\d{2}(?::\d{2})?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let valueRange = Range(match.range, in: text) else { return nil }
            return parseClock(String(text[valueRange]))
        }
    }

    private func containsClock(_ text: String) -> Bool {
        !clockValues(in: text).isEmpty
    }

    private func isOCRControlLabel(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return isNavigationText(lowered) || lowered.contains("下一首") || lowered.contains("上一首") ||
            lowered.contains("音量") || lowered.contains("收藏") || lowered.contains("分享") ||
            lowered.contains("更多") || lowered.contains("歌词") || lowered.contains("循环") ||
            lowered.contains("随机") || lowered.contains("download") || lowered.contains("like") ||
            lowered.contains("share") || lowered.contains("more") || lowered.contains("lyrics") ||
            lowered.contains("queue")
    }

    private func isPlayOCRLabel(_ text: String) -> Bool {
        guard text.contains("播放") || hasStandaloneWord("play", in: text) else { return false }
        return !text.contains("播放列表") && !text.contains("播放全部") && !text.contains("播放歌单")
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) { values.append(value) }
    }

    private func publishSnapshot(_ next: PlayerSnapshot?) {
        if next?.identityEvidence != .candidate && (snapshot != nil || next != nil) {
            pendingOCRKey = nil
            pendingOCRObservedAt = nil
        }
        let previous = snapshot

        // PlayerSnapshot equality intentionally ignores observedAt so a
        // polling tick with the same values does not emit an event.  Still
        // publish the fresh observation time, which is used as evidence for
        // capture coverage and process continuity.
        if let next, previous == next {
            snapshot = next
            return
        }

        guard previous != next else { return }

        snapshot = next
        guard let next else {
            // A missing snapshot is meaningful to an active capture: it
            // closes the old identity boundary when the player exits, its
            // PID changes, or access disappears.
            if previous != nil { emit(.unavailable) }
            return
        }
        guard let previous else {
            emit(.trackChanged(next))
            return
        }

        if previous.candidateKey != next.candidateKey {
            emit(.trackChanged(next))
        } else if previous.playbackState != next.playbackState {
            emit(.playbackStateChanged(next.playbackState))
        } else if previous.currentTime != next.currentTime || previous.duration != next.duration {
            emit(.positionChanged(currentTime: next.currentTime, duration: next.duration))
        } else if previous.title != next.title || previous.artist != next.artist ||
                    previous.album != next.album || previous.trackID != next.trackID ||
                    previous.trackURL != next.trackURL {
            emit(.metadataUpdated(next))
        }
    }

    private func emit(_ event: PlayerObserverEvent) {
        lastEvent = event
        eventHandler?(event)
    }
}

// MARK: - Value parsing helpers

private func copyAttribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard result == .success, let value else { return nil }
    return value
}

private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSString { return value as String }
    if let value = value as? URL { return value.absoluteString }
    if let value = value as? NSURL { return value.absoluteString }
    return nil
}

private func numberValue(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? Double { return value }
    if let value = value as? Float { return Double(value) }
    if let value = value as? Int { return Double(value) }
    return nil
}

private func normalize(_ value: String) -> String {
    value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func urlValue(_ value: Any?) -> URL? {
    if let value = value as? URL { return value }
    if let value = value as? NSURL { return value as URL }
    guard let value = stringValue(value) else { return nil }
    return firstURL(in: value)
}

private func firstURL(in text: String) -> URL? {
    let patterns = [
        #"https?://[^\s<>\"]+"#,
        #"orpheus://[^\s<>\"]+"#
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text),
              let url = URL(string: String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ",.;，。！？）》"))) else { continue }
        return url
    }
    return nil
}

private func isTrackURL(_ url: URL?) -> Bool {
    guard let url else { return false }
    if url.scheme?.lowercased() == "orpheus" {
        return url.path.lowercased().contains("song") || url.host?.lowercased() == "song"
    }
    guard let host = url.host?.lowercased(),
          host == "music.163.com" || host.hasSuffix(".music.163.com") else { return false }
    let path = url.path.lowercased()
    if path.contains("/song") { return true }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
        $0.name.lowercased() == "id" && ($0.value?.allSatisfy(\.isNumber) ?? false)
    } ?? false
}

private func trackID(from url: URL?) -> String? {
    guard let url, isTrackURL(url) else { return nil }
    if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
        $0.name.lowercased() == "id"
    })?.value, id.allSatisfy(\.isNumber), !id.isEmpty {
        return id
    }

    if url.scheme?.lowercased() == "orpheus", url.host?.lowercased() == "song" {
        if let value = url.pathComponents.dropFirst().first(where: { $0.allSatisfy(\.isNumber) }), !value.isEmpty {
            return value
        }
    }

    let components = url.pathComponents
    guard let index = components.lastIndex(where: { $0.lowercased() == "song" }),
          index + 1 < components.count else { return nil }
    let value = components[index + 1]
    return value.allSatisfy(\.isNumber) && !value.isEmpty ? value : nil
}

private func isNavigationText(_ value: String) -> Bool {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let exact = [
        "发现", "推荐", "歌单", "音乐", "播客", "视频", "直播", "关注", "我的", "私人fm",
        "播放", "暂停", "播放列表", "播放全部", "下一首", "上一首", "音量", "搜索",
        "discover", "recommend", "playlist", "podcast", "video", "following", "search"
    ]
    return exact.contains(text)
}

private func containsNowPlayingContext(_ value: String) -> Bool {
    ["正在播放", "播放中", "当前播放", "now playing", "now_playing", "mini player", "mini-player"]
        .contains { value.contains($0) }
}

private func stripNowPlayingContext(_ value: String) -> String {
    var result = value
    let patterns = [
        #"(?i)^\s*(?:正在播放|播放中|当前播放|now playing|now_playing|mini player|mini-player)\s*[:：-]?\s*"#
    ]
    for pattern in patterns {
        result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return normalize(result)
}

private func hasStandaloneWord(_ word: String, in value: String) -> Bool {
    let pattern = "(^|[^a-z])\(word)([^a-z]|$)"
    return value.range(of: pattern, options: .regularExpression) != nil
}

private func firstMatch(pattern: String, in value: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, options: [], range: range) else { return nil }
    return (0..<match.numberOfRanges).map { index in
        let matchRange = match.range(at: index)
        guard matchRange.location != NSNotFound,
              let range = Range(matchRange, in: value) else { return nil }
        return String(value[range])
    }
}

private func parseClock(_ value: String?) -> TimeInterval? {
    guard let value else { return nil }
    let pieces = value.split(separator: ":").compactMap { Double($0) }
    guard pieces.count == 2 || pieces.count == 3 else { return nil }
    if pieces.count == 2 { return pieces[0] * 60 + pieces[1] }
    return pieces[0] * 3_600 + pieces[1] * 60 + pieces[2]
}

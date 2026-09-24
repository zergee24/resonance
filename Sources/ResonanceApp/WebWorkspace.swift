import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

/// The public, page-facing bridge used by the app's "My headphones" and
/// playlist import flows.
///
/// The bridge deliberately evaluates extraction code in the loaded page. It
/// does not call a site's private API, copy cookies into URLSession, or turn a
/// screenshot into data. Authentication, when needed, is therefore the
/// normal authentication flow rendered by WKWebView's persistent data store.
@MainActor
public final class WebWorkspace: NSViewController, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    public enum CurveKind: String, Codable, Hashable, Sendable {
        case frequencyResponse
        case harmonicDistortion
        case phase
        case impedance
        case dynamicDeviation
        case unknown
    }

    public struct CurvePoint: Codable, Hashable, Sendable {
        public let frequencyHz: Double
        public let decibels: Double

        public init(frequencyHz: Double, decibels: Double) {
            self.frequencyHz = frequencyHz
            self.decibels = decibels
        }
    }

    public struct CurveCandidate: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let sourceURL: URL
        public let extractedAt: String
        public let chartTitle: String?
        public let seriesName: String
        public let curveKind: CurveKind
        public let channel: String?
        public let role: String
        public let points: [CurvePoint]
        public let sourceElementID: String?
        public let xAxisName: String?
        public let yAxisName: String?
        public let hasLogarithmicXAxis: Bool
        /// `echartsInstance` when read through a public ECharts instance;
        /// `reactProps` when read from an already mounted public React option.
        public let extractionSource: String
        public let evidencePath: String?
        public let isSelectable: Bool

        public init(
            id: String,
            sourceURL: URL,
            extractedAt: String,
            chartTitle: String?,
            seriesName: String,
            curveKind: CurveKind,
            channel: String?,
            role: String,
            points: [CurvePoint],
            sourceElementID: String?,
            xAxisName: String?,
            yAxisName: String?,
            hasLogarithmicXAxis: Bool,
            isSelectable: Bool,
            extractionSource: String = "unknown",
            evidencePath: String? = nil
        ) {
            self.id = id
            self.sourceURL = sourceURL
            self.extractedAt = extractedAt
            self.chartTitle = chartTitle
            self.seriesName = seriesName
            self.curveKind = curveKind
            self.channel = channel
            self.role = role
            self.points = points
            self.sourceElementID = sourceElementID
            self.xAxisName = xAxisName
            self.yAxisName = yAxisName
            self.hasLogarithmicXAxis = hasLogarithmicXAxis
            self.extractionSource = extractionSource
            self.evidencePath = evidencePath
            self.isSelectable = isSelectable
        }
    }

    public enum PlaylistCompleteness: String, Codable, Hashable, Sendable {
        case complete
        case partial
        case notProven
    }

    public struct PlaylistTrack: Codable, Hashable, Identifiable, Sendable {
        /// This is the platform track ID, not a local recording/session ID.
        public let id: String
        public let name: String?
        public let artists: String?
        /// Zero-based source DOM order. Duplicate source rows are preserved.
        public let order: Int
        public let url: URL
        public let sourceText: String?

        public init(
            id: String,
            name: String?,
            artists: String?,
            order: Int,
            url: URL,
            sourceText: String?
        ) {
            self.id = id
            self.name = name
            self.artists = artists
            self.order = order
            self.url = url
            self.sourceText = sourceText
        }
    }

    public struct PlaylistExtraction: Codable, Hashable, Sendable {
        public let sourceURL: URL
        public let playlistID: String?
        public let playlistName: String?
        public let extractedAt: String
        public let tracks: [PlaylistTrack]
        public let totalCount: Int?
        public let completeness: PlaylistCompleteness
        public let completenessReason: String
        public let warnings: [String]

        public init(
            sourceURL: URL,
            playlistID: String?,
            playlistName: String?,
            extractedAt: String,
            tracks: [PlaylistTrack],
            totalCount: Int?,
            completeness: PlaylistCompleteness,
            completenessReason: String,
            warnings: [String]
        ) {
            self.sourceURL = sourceURL
            self.playlistID = playlistID
            self.playlistName = playlistName
            self.extractedAt = extractedAt
            self.tracks = tracks
            self.totalCount = totalCount
            self.completeness = completeness
            self.completenessReason = completenessReason
            self.warnings = warnings
        }
    }

    public enum PlaylistWriteStatus: String, Codable, Hashable, Sendable {
        case started
        case verified
        case partiallyWritten
        case createdUnknown
        case readbackIncomplete
        case failed
    }

    /// Immutable contents shown by the host UI before a write is authorized.
    /// Creating this value has no page side effect.
    public struct PlaylistWritePreview: Codable, Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let sourceURL: URL
        public let targetPlaylistID: String?
        public let targetPlaylistURL: URL?
        public let tracks: [PlaylistTrack]
        public let createdAt: String

        public init(
            id: UUID = UUID(),
            name: String,
            sourceURL: URL,
            targetPlaylistID: String?,
            targetPlaylistURL: URL?,
            tracks: [PlaylistTrack],
            createdAt: String
        ) {
            self.id = id
            self.name = name
            self.sourceURL = sourceURL
            self.targetPlaylistID = targetPlaylistID
            self.targetPlaylistURL = targetPlaylistURL
            self.tracks = tracks
            self.createdAt = createdAt
        }
    }

    public struct PlaylistWriteResult: Codable, Hashable, Sendable {
        public let previewID: UUID
        public let accountID: String?
        public let status: PlaylistWriteStatus
        public let sourceURL: URL
        public let targetPlaylistID: String?
        public let targetPlaylistURL: URL?
        public let expectedTrackIDs: [String]
        public let writtenTrackIDs: [String]
        public let missingTrackIDs: [String]
        public let observedTrackIDs: [String]
        public let orderMatches: Bool?
        public let message: String

        public init(
            previewID: UUID,
            accountID: String? = nil,
            status: PlaylistWriteStatus,
            sourceURL: URL,
            targetPlaylistID: String?,
            targetPlaylistURL: URL?,
            expectedTrackIDs: [String],
            writtenTrackIDs: [String],
            missingTrackIDs: [String],
            observedTrackIDs: [String],
            orderMatches: Bool?,
            message: String
        ) {
            self.previewID = previewID
            self.accountID = accountID
            self.status = status
            self.sourceURL = sourceURL
            self.targetPlaylistID = targetPlaylistID
            self.targetPlaylistURL = targetPlaylistURL
            self.expectedTrackIDs = expectedTrackIDs
            self.writtenTrackIDs = writtenTrackIDs
            self.missingTrackIDs = missingTrackIDs
            self.observedTrackIDs = observedTrackIDs
            self.orderMatches = orderMatches
            self.message = message
        }
    }

    public struct PlaylistWriteJournalEntry: Codable, Hashable, Sendable, Identifiable {
        public let id: UUID
        public let previewID: UUID
        public let accountID: String
        public let targetPlaylistID: String?
        public let expectedTrackIDs: [String]
        public let writtenTrackIDs: [String]
        public let status: PlaylistWriteStatus
        public let updatedAt: String
        public let message: String

        public init(
            id: UUID = UUID(),
            previewID: UUID,
            accountID: String,
            targetPlaylistID: String?,
            expectedTrackIDs: [String],
            writtenTrackIDs: [String],
            status: PlaylistWriteStatus,
            updatedAt: String,
            message: String
        ) {
            self.id = id
            self.previewID = previewID
            self.accountID = accountID
            self.targetPlaylistID = targetPlaylistID
            self.expectedTrackIDs = expectedTrackIDs
            self.writtenTrackIDs = writtenTrackIDs
            self.status = status
            self.updatedAt = updatedAt
            self.message = message
        }
    }

    public enum WebWorkspaceError: LocalizedError, Equatable, Sendable {
        case unsupportedURLScheme
        case navigationFailed(String)
        case navigationTimedOut
        case navigationSuperseded
        case pageNotLoaded
        case scriptResourceMissing(String)
        case scriptEvaluationFailed(String)
        case invalidScriptResult
        case invalidSourceURL
        case playlistExportUnavailable(String)
        case playlistJournalUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedURLScheme:
                return "仅允许在应用内打开 HTTP 或 HTTPS 页面。"
            case let .navigationFailed(message):
                return "网页加载失败：\(message)"
            case .navigationTimedOut:
                return "网页加载超过等待时间。"
            case .navigationSuperseded:
                return "网页加载已被新的导航替代。"
            case .pageNotLoaded:
                return "当前没有已完成加载的网页。"
            case let .scriptResourceMissing(name):
                return "应用缺少页面提取脚本：\(name)。"
            case let .scriptEvaluationFailed(message):
                return "页面数据提取失败：\(message)"
            case .invalidScriptResult:
                return "页面返回的数据格式无法核验。"
            case .invalidSourceURL:
                return "页面返回了无效来源链接。"
            case let .playlistExportUnavailable(reason):
                return "当前版本不能通过正常网页界面可靠完成歌单写入：\(reason)"
            case let .playlistJournalUnavailable(reason):
                return "网易云写入 journal 不可用，已停用写入：\(reason)"
            }
        }
    }

    /// The WKWebView is public so the host SwiftUI screen can embed the
    /// browser directly or use `WebWorkspaceView` below.
    public let browserView: WKWebView

    @Published public private(set) var curveCandidates: [CurveCandidate] = []
    @Published public private(set) var curveWarnings: [String] = []
    @Published public private(set) var playlistExtraction: PlaylistExtraction?
    @Published public private(set) var playlistWriteJournal: [PlaylistWriteJournalEntry] = []
    @Published public private(set) var playlistJournalError: String?
    @Published public private(set) var loadedPageURL: URL?
    @Published public private(set) var isLoading = false

    private var pageLoadReady = false
    private var navigationGeneration = 0
    private var pendingLoad: CheckedContinuation<Void, Error>?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var playlistWriterScript: String?
    private var activeWriteAccountID: String?

    public init(configuration: WKWebViewConfiguration? = nil) {
        let webConfiguration = configuration ?? Self.makeConfiguration()
        self.browserView = WKWebView(frame: .zero, configuration: webConfiguration)
        super.init(nibName: nil, bundle: nil)

        browserView.navigationDelegate = self
        browserView.uiDelegate = self
        browserView.allowsBackForwardNavigationGestures = true
        browserView.setValue(false, forKey: "drawsBackground")
        loadPlaylistWriteJournal()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("WebWorkspace must be created with init(configuration:)")
    }

    public override func loadView() {
        view = browserView
    }

    deinit {
        navigationTimeoutTask?.cancel()
        pendingLoad?.resume(throwing: WebWorkspaceError.navigationSuperseded)
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // The default store keeps the user's normal web login inside the
        // application. Credentials are never copied into a request by us.
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    /// Starts a normal web navigation. Use `waitForLoad()` or
    /// `loadAndWait(url:)` before extracting page data.
    @discardableResult
    public func load(url: URL) -> WKNavigation? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        cancelPendingLoad(with: WebWorkspaceError.navigationSuperseded)
        navigationGeneration &+= 1
        pageLoadReady = false
        isLoading = true
        loadedPageURL = url
        curveCandidates = []
        curveWarnings = []
        playlistExtraction = nil
        return browserView.load(URLRequest(url: url))
    }

    /// Starts a normal navigation and waits for WebKit's didFinish callback.
    public func loadAndWait(url: URL, timeout: TimeInterval = 30) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw WebWorkspaceError.unsupportedURLScheme
        }
        _ = load(url: url)
        try await waitForLoad(timeout: timeout)
    }

    /// Waits for the current normal page navigation. This is separate from
    /// `load(url:)` so callers can show the browser immediately in SwiftUI.
    public func waitForLoad(timeout: TimeInterval = 30) async throws {
        if pageLoadReady && !isLoading { return }
        guard isLoading else { throw WebWorkspaceError.pageNotLoaded }

        let generation = navigationGeneration
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingLoad = continuation
            navigationTimeoutTask?.cancel()
            let nanoseconds = UInt64(max(0.1, timeout) * 1_000_000_000)
            navigationTimeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard let self, self.navigationGeneration == generation, self.isLoading else { return }
                self.finishNavigation(.failure(WebWorkspaceError.navigationTimedOut), generation: generation)
            }
        }
    }

    /// Reads every numeric ECharts series that the loaded page exposes. The
    /// returned candidates intentionally include curve kind/role so the caller
    /// can let the user select the target frequency-response series instead of
    /// silently confusing it with THD, phase, impedance, or a reference line.
    public func extractCurves() async throws -> [CurveCandidate] {
        try await ensurePageReady()
        let script = try Self.loadResourceScript(named: "curve_extractor")
        let envelope: CurveEnvelope
        do {
            envelope = try await evaluateJSON(script, as: CurveEnvelope.self)
        } catch let error as WebWorkspaceError {
            throw error
        } catch {
            throw WebWorkspaceError.scriptEvaluationFailed(error.localizedDescription)
        }

        guard let sourceURLString = envelope.pageURL ?? browserView.url?.absoluteString,
              let sourceURL = URL(string: sourceURLString),
              sourceURL.scheme != nil else {
            throw WebWorkspaceError.invalidSourceURL
        }
        let extractedAt = envelope.extractedAt ?? ISO8601DateFormatter().string(from: Date())
        let candidates = envelope.curves.compactMap { rawCurve -> CurveCandidate? in
            guard rawCurve.points.count >= 2 else { return nil }
            return CurveCandidate(
                id: rawCurve.id,
                sourceURL: sourceURL,
                extractedAt: extractedAt,
                chartTitle: rawCurve.chartTitle,
                seriesName: rawCurve.seriesName,
                curveKind: CurveKind(rawValue: rawCurve.curveKind) ?? .unknown,
                channel: rawCurve.channel,
                role: rawCurve.role ?? "unknown",
                points: rawCurve.points.map { CurvePoint(frequencyHz: $0.frequencyHz, decibels: $0.decibels) },
                sourceElementID: rawCurve.sourceElementID,
                xAxisName: rawCurve.xAxisName,
                yAxisName: rawCurve.yAxisName,
                hasLogarithmicXAxis: rawCurve.hasLogarithmicXAxis,
                isSelectable: rawCurve.selectable,
                extractionSource: rawCurve.extractionSource ?? "unknown",
                evidencePath: rawCurve.evidencePath
            )
        }
        curveCandidates = candidates
        curveWarnings = envelope.warnings
        return candidates
    }

    /// Reads the rows currently rendered by the normal NetEase playlist page.
    /// A virtualized or paginated page is returned as partial/notProven and is
    /// never promoted to a complete snapshot merely because some rows exist.
    public func extractPlaylist() async throws -> PlaylistExtraction {
        try await ensurePageReady()
        let script = try Self.loadResourceScript(named: "playlist_extractor")
        var raw: PlaylistEnvelope
        do {
            raw = try await evaluateJSON(script, as: PlaylistEnvelope.self)
        } catch let error as WebWorkspaceError {
            throw error
        } catch {
            throw WebWorkspaceError.scriptEvaluationFailed(error.localizedDescription)
        }
        // music.163.com's normal shell finishes before its same-origin
        // `#g_iframe` content. Give that public DOM a short settling window;
        // this is still page observation, never a private endpoint request.
        if raw.tracks.isEmpty, browserView.url?.host?.contains("music.163.com") == true {
            for _ in 0..<20 where raw.tracks.isEmpty {
                try await Task.sleep(nanoseconds: 250_000_000)
                raw = try await evaluateJSON(script, as: PlaylistEnvelope.self)
            }
        }

        guard let sourceURLString = raw.sourceURL,
              let sourceURL = URL(string: sourceURLString),
              sourceURL.scheme != nil else {
            throw WebWorkspaceError.invalidSourceURL
        }
        let extractedAt = raw.extractedAt ?? ISO8601DateFormatter().string(from: Date())
        let tracks = raw.tracks.compactMap { item -> PlaylistTrack? in
            guard let url = URL(string: item.url) else { return nil }
            return PlaylistTrack(
                id: item.id,
                name: item.name,
                artists: item.artists,
                order: item.order,
                url: url,
                sourceText: item.sourceText
            )
        }
        let completeness = PlaylistCompleteness(rawValue: raw.completeness) ?? .notProven
        let result = PlaylistExtraction(
            sourceURL: sourceURL,
            playlistID: raw.playlistID,
            playlistName: raw.playlistName,
            extractedAt: extractedAt,
            tracks: tracks,
            totalCount: raw.totalCount,
            completeness: completeness,
            completenessReason: raw.completenessReason,
            warnings: raw.warnings
        )
        playlistExtraction = result
        return result
    }

    /// Builds the exact list that the host UI can show for review. This method
    /// does not navigate, click, or mutate the user's account.
    public func makePlaylistWritePreview(
        name: String,
        tracks: [PlaylistTrack],
        sourceURL: URL? = nil,
        targetPlaylistURL: URL? = nil
    ) throws -> PlaylistWritePreview {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw WebWorkspaceError.playlistExportUnavailable("歌单名称不能为空。")
        }
        guard !tracks.isEmpty else {
            throw WebWorkspaceError.playlistExportUnavailable("预览中没有可写入的精确歌曲 ID。")
        }
        guard let resolvedSource = sourceURL ?? browserView.url,
              let scheme = resolvedSource.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw WebWorkspaceError.invalidSourceURL
        }
        var seenTrackIDs = Set<String>()
        let uniqueTracks = tracks.filter { seenTrackIDs.insert($0.id).inserted }
        guard !uniqueTracks.isEmpty else {
            throw WebWorkspaceError.playlistExportUnavailable("预览中的曲目 ID 去重后为空。")
        }
        let targetID = targetPlaylistURL.flatMap(Self.playlistID(from:))
        return PlaylistWritePreview(
            name: normalizedName,
            sourceURL: resolvedSource,
            targetPlaylistID: targetID,
            targetPlaylistURL: targetPlaylistURL,
            tracks: uniqueTracks,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Performs a user-authorized write through the normal NetEase webpage.
    /// `authorized` must only be set by the host's explicit preview action.
    /// The method stops on the first uncertain step and returns the IDs that
    /// were completed; it never retries a whole batch or deletes a playlist.
    public func exportPlaylistThroughNormalUI(
        preview: PlaylistWritePreview,
        authorized: Bool
    ) async throws -> PlaylistWriteResult {
        guard authorized else {
            throw WebWorkspaceError.playlistExportUnavailable("必须从歌单预览按钮明确授权本次写入。")
        }
        guard !preview.tracks.isEmpty else {
            throw WebWorkspaceError.playlistExportUnavailable("预览中没有可写入的精确歌曲 ID。")
        }
        guard playlistJournalError == nil else {
            throw WebWorkspaceError.playlistJournalUnavailable(playlistJournalError ?? "本地 journal 不可用。")
        }
        try await ensurePageReady()
        if browserView.url?.absoluteString != preview.sourceURL.absoluteString {
            try await loadAndWait(url: preview.sourceURL)
        }

        let accountID = try await verifyCurrentAccount()
        activeWriteAccountID = accountID
        defer { activeWriteAccountID = nil }
        let previous = playlistWriteJournal.first(where: { $0.previewID == preview.id })
        if let previous {
            if previous.status == .verified {
                throw WebWorkspaceError.playlistExportUnavailable("该预览已经完成写后核对，未重复执行。")
            }
            if previous.targetPlaylistID == nil,
               preview.targetPlaylistID == nil,
               [.started, .createdUnknown, .partiallyWritten, .readbackIncomplete].contains(previous.status) {
                throw WebWorkspaceError.playlistExportUnavailable(
                    "该预览的新建结果可能已发生但目标 ID 未知；请先在网易云页面确认目标歌单并绑定后再继续，已禁止重复新建。"
                )
            }
            if let previousTarget = previous.targetPlaylistID,
               let requestedTarget = preview.targetPlaylistID,
               previousTarget != requestedTarget {
                throw WebWorkspaceError.playlistExportUnavailable("同一预览的 journal 目标歌单与当前预览不一致，已停止。")
            }
        }
        try recordPlaylistWrite(
            preview: preview,
            accountID: accountID,
            targetID: previous?.targetPlaylistID ?? preview.targetPlaylistID,
            writtenIDs: previous?.writtenTrackIDs ?? [],
            status: .started,
            message: "已从正常页面识别当前账号，等待逐曲预览写入。"
        )

        // Re-read the source page before any account mutation. This catches a
        // stale preview or a page that is not the expected playlist.
        let sourceSnapshot = try await extractPlaylist()
        let expectedIDs = preview.tracks.map(\.id)
        let renderedIDs = Set(sourceSnapshot.tracks.map(\.id))
        let sourceHasRenderedTracks = expectedIDs.contains(where: renderedIDs.contains)
        let sourceCanNavigateTracks = preview.tracks.allSatisfy { $0.url.scheme != nil }
        guard sourceHasRenderedTracks || sourceCanNavigateTracks else {
            return try makeWriteResult(
                preview: preview,
                status: .failed,
                targetID: preview.targetPlaylistID,
                writtenIDs: [],
                observedIDs: [],
                orderMatches: nil,
                message: "当前正常页面没有预览中的任何歌曲行，且预览没有可导航的歌曲链接；可能是歌单未展开或页面已变化。"
            )
        }

        let firstRenderedTrack = preview.tracks.first { renderedIDs.contains($0.id) } ?? preview.tracks.first
        var targetID = previous?.targetPlaylistID ?? preview.targetPlaylistID
        var targetURL = preview.targetPlaylistURL
        var writtenIDs = previous?.writtenTrackIDs ?? []
        let creatingNewTarget = targetID == nil

        if targetID == nil {
            guard let firstRenderedTrack else {
                return try makeWriteResult(
                    preview: preview,
                    status: .failed,
                    targetID: nil,
                    writtenIDs: [],
                    observedIDs: [],
                    orderMatches: nil,
                    message: "没有可用于打开正常添加窗口的已渲染歌曲。"
                )
            }
            if !renderedIDs.contains(firstRenderedTrack.id) {
                try await loadAndWait(url: firstRenderedTrack.url)
            }
            _ = try await verifyCurrentAccount(expected: accountID)
            let before = try await openPlaylistAddWindow(for: firstRenderedTrack.id, preview: preview)
            let beforeIDs = Set(before.items?.compactMap(\.id) ?? [])
            var createSubmitted = false
            for _ in 0..<3 {
                _ = try await verifyCurrentAccount(expected: accountID)
                // The normal page click may create a playlist even if the
                // process dies before its newly assigned ID is observable.
                // Persist the conservative unknown state before every such
                // click so a restart cannot create a second playlist.
                try recordPlaylistWrite(
                    preview: preview,
                    accountID: accountID,
                    targetID: nil,
                    writtenIDs: writtenIDs,
                    status: .createdUnknown,
                    message: "已准备/触发新建歌单网页操作；目标 ID 尚未核验，禁止重放新建。"
                )
                let create = try await runPlaylistWriter(
                    operation: "createPlaylist",
                    payload: WriterPayload(name: preview.name)
                )
                if !create.ok {
                    return try makeWriteResult(
                        preview: preview,
                        status: .createdUnknown,
                        targetID: nil,
                        writtenIDs: [],
                        observedIDs: [],
                        orderMatches: nil,
                        message: "新建歌单网页操作返回不确定状态（\(create.message ?? "未返回原因")）；已停止且禁止重复新建。"
                    )
                }
                if create.stage == "createSubmitted" {
                    createSubmitted = true
                    break
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard createSubmitted else {
                return try makeWriteResult(
                    preview: preview,
                    status: .createdUnknown,
                    targetID: nil,
                    writtenIDs: [],
                    observedIDs: [],
                    orderMatches: nil,
                    message: "新建歌单窗口没有确认完成提交；结果按未知处理，未继续添加且禁止重复新建。"
                )
            }

            do {
                _ = try await waitForPlaylistCreateDialogToClose(timeout: 8)
                // Reopen the normal add window after creation. The visible list
                // is the only source used to discover the newly assigned ID.
                _ = try await verifyCurrentAccount(expected: accountID)
                if !renderedIDs.contains(firstRenderedTrack.id) {
                    try await loadAndWait(url: firstRenderedTrack.url)
                }
                _ = try await openPlaylistAddWindow(for: firstRenderedTrack.id, preview: preview)
                let after = try await waitForPlaylistWriter(
                    operation: "listPlaylists",
                    payload: WriterPayload(),
                    timeout: 8
                ) { result in
                    (result.items ?? []).contains { item in
                        guard let id = item.id else { return false }
                        return !beforeIDs.contains(id)
                    }
                }
                let created = (after.items ?? []).first {
                    guard let id = $0.id else { return false }
                    return !beforeIDs.contains(id) && $0.name == preview.name
                } ?? (after.items ?? []).first {
                    guard let id = $0.id else { return false }
                    return !beforeIDs.contains(id)
                }
                guard let created, let createdID = created.id else {
                    return try makeWriteResult(
                        preview: preview,
                        status: .createdUnknown,
                        targetID: nil,
                        writtenIDs: [],
                        observedIDs: [],
                        orderMatches: nil,
                        message: "新建提交结果未知，正常页面没有返回可核验的目标歌单 ID；已停止且写入日志标记为 createdUnknown，避免重复新建。"
                    )
                }
                targetID = createdID
                targetURL = Self.playlistURL(id: createdID, fallback: preview.sourceURL)
                try recordPlaylistWrite(
                    preview: preview,
                    accountID: accountID,
                    targetID: createdID,
                    writtenIDs: writtenIDs,
                    status: .partiallyWritten,
                    message: "已从正常页面核验新建歌单 ID，后续曲目操作可从该目标恢复。"
                )
            } catch {
                return try makeWriteResult(
                    preview: preview,
                    status: .createdUnknown,
                    targetID: nil,
                    writtenIDs: [],
                    observedIDs: [],
                    orderMatches: nil,
                    message: "新建歌单已提交但目标 ID 回读失败（\(error.localizedDescription)）；已停止且写入日志标记为 createdUnknown，避免重复新建。"
                )
            }
        }

        guard let targetID else {
            throw WebWorkspaceError.playlistExportUnavailable("无法确认目标歌单 ID。")
        }
        if targetURL == nil {
            targetURL = Self.playlistURL(id: targetID, fallback: preview.sourceURL)
        }

        for track in preview.tracks {
            if writtenIDs.contains(track.id) { continue }
            do {
                if !(sourceHasRenderedTracks && renderedIDs.contains(track.id) && browserView.url?.absoluteString == preview.sourceURL.absoluteString) {
                    try await loadAndWait(url: track.url)
                }
                _ = try await verifyCurrentAccount(expected: accountID)
                _ = try await openPlaylistAddWindow(for: track.id, preview: preview)
                _ = try await verifyCurrentAccount(expected: accountID)
                let selected = try await runPlaylistWriter(
                    operation: "selectTarget",
                    payload: WriterPayload(targetPlaylistID: targetID)
                )
                guard selected.ok else {
                    return try makeWriteResult(
                        preview: preview,
                        status: writtenIDs.isEmpty ? .failed : .partiallyWritten,
                        targetID: targetID,
                        writtenIDs: writtenIDs,
                        observedIDs: [],
                        orderMatches: nil,
                        message: "歌曲 \(track.id) 未能选择目标歌单：\(selected.message ?? "目标歌单未出现在当前窗口")"
                    )
                }
                _ = try await waitForPlaylistModalToClose(timeout: 8)
                writtenIDs.append(track.id)
                try recordPlaylistWrite(
                    preview: preview,
                    accountID: accountID,
                    targetID: targetID,
                    writtenIDs: writtenIDs,
                    status: .partiallyWritten,
                    message: "已通过正常页面完成歌曲 \(track.id) 的一次添加动作，等待后续曲目和回读。"
                )
            } catch {
                return try makeWriteResult(
                    preview: preview,
                    status: writtenIDs.isEmpty ? .failed : .partiallyWritten,
                    targetID: targetID,
                    writtenIDs: writtenIDs,
                    observedIDs: [],
                    orderMatches: nil,
                    message: "歌曲 \(track.id) 的网页操作未完成：\(error.localizedDescription)。已保留已完成 ID，可从同一预览继续处理。"
                )
            }
        }

        guard let targetURL else {
            return try makeWriteResult(
                preview: preview,
                status: .partiallyWritten,
                targetID: targetID,
                writtenIDs: writtenIDs,
                observedIDs: [],
                orderMatches: nil,
                message: "歌曲已通过正常页面操作提交，但无法构造目标歌单链接，未宣称写后核对完成。"
            )
        }

        do {
            try await loadAndWait(url: targetURL)
            let readback = try await extractPlaylist()
            let observedIDs = readback.tracks.map(\.id)
            let missingIDs = expectedIDs.filter { !observedIDs.contains($0) }
            let orderMatches = Self.isSubsequence(expectedIDs, in: observedIDs)
            let expectedReadbackIDs = creatingNewTarget ? expectedIDs : nil
            let fullyVerified = readback.completeness == .complete
                && (expectedReadbackIDs == nil
                    ? (missingIDs.isEmpty && orderMatches)
                    : observedIDs == expectedReadbackIDs!)
            return try makeWriteResult(
                preview: preview,
                status: fullyVerified ? .verified : .readbackIncomplete,
                targetID: targetID,
                writtenIDs: writtenIDs,
                observedIDs: observedIDs,
                orderMatches: orderMatches,
                message: fullyVerified
                    ? "目标歌单已通过正常页面重新打开，并核对了歌曲 ID、数量和顺序。"
                    : "网页操作已完成，但目标歌单读取结果不完整或仍有缺失 ID；保留目标链接和已观察结果，未宣称全部写入。",
                targetURL: targetURL
            )
        } catch {
            return try makeWriteResult(
                preview: preview,
                status: .readbackIncomplete,
                targetID: targetID,
                writtenIDs: writtenIDs,
                observedIDs: [],
                orderMatches: nil,
                message: "网页操作已完成，但目标歌单回读失败：\(error.localizedDescription)。请从目标链接人工核对后再继续。"
            )
        }
    }

    /// Retained as a guard for older callers: without a concrete preview and
    /// authorization this overload never mutates the account.
    public func exportPlaylistThroughNormalUI() async throws {
        throw WebWorkspaceError.playlistExportUnavailable("请先生成歌单预览，并从预览按钮授权明确的曲目列表。")
    }

    private func openPlaylistAddWindow(for trackID: String, preview _: PlaylistWritePreview) async throws -> WriterResult {
        let request = try await runPlaylistWriter(
            operation: "openAdd",
            payload: WriterPayload(trackID: trackID)
        )
        guard request.ok else {
            throw WebWorkspaceError.playlistExportUnavailable(
                request.message ?? "当前正常页面没有该歌曲的添加入口。"
            )
        }
        _ = try await waitForPlaylistWriter(
            operation: "modalState",
            payload: WriterPayload(),
            timeout: 8
        ) { $0.visible == true }
        let list = try await runPlaylistWriter(
            operation: "listPlaylists",
            payload: WriterPayload()
        )
        guard list.ok else {
            throw WebWorkspaceError.playlistExportUnavailable(
                list.message ?? "当前正常页面没有可核验的目标歌单列表。"
            )
        }
        return list
    }

    private func waitForPlaylistCreateDialogToClose(timeout: TimeInterval) async throws -> WriterResult {
        try await waitForPlaylistWriter(
            operation: "createState",
            payload: WriterPayload(),
            timeout: timeout
        ) { $0.visible == false }
    }

    private func waitForPlaylistModalToClose(timeout: TimeInterval) async throws -> WriterResult {
        try await waitForPlaylistWriter(
            operation: "modalState",
            payload: WriterPayload(),
            timeout: timeout
        ) { $0.visible == false }
    }

    private func runPlaylistWriter(operation: String, payload: WriterPayload) async throws -> WriterResult {
        if playlistWriterScript == nil {
            playlistWriterScript = try Self.loadResourceScript(named: "playlist_writer")
        }
        guard let script = playlistWriterScript else {
            throw WebWorkspaceError.scriptResourceMissing("playlist_writer.js")
        }
        let operationData = try JSONEncoder().encode(operation)
        let operationJSON = String(decoding: operationData, as: UTF8.self)
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)
        return try await evaluateJSON("\(script)(\(operationJSON), \(payloadJSON))", as: WriterResult.self)
    }

    private func waitForPlaylistWriter(
        operation: String,
        payload: WriterPayload,
        timeout: TimeInterval,
        where predicate: (WriterResult) -> Bool
    ) async throws -> WriterResult {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var lastResult: WriterResult?
        while Date() < deadline {
            let result = try await runPlaylistWriter(operation: operation, payload: payload)
            lastResult = result
            if predicate(result) { return result }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw WebWorkspaceError.playlistExportUnavailable(
            lastResult?.message ?? "正常网页界面在规定时间内没有进入预期状态。"
        )
    }

    private func makeWriteResult(
        preview: PlaylistWritePreview,
        status: PlaylistWriteStatus,
        targetID: String?,
        writtenIDs: [String],
        observedIDs: [String],
        orderMatches: Bool?,
        message: String,
        targetURL: URL? = nil
    ) throws -> PlaylistWriteResult {
        let expectedIDs = preview.tracks.map(\.id)
        let missingIDs = expectedIDs.filter { !observedIDs.contains($0) }
        if let accountID = activeWriteAccountID {
            try recordPlaylistWrite(
                preview: preview,
                accountID: accountID,
                targetID: targetID,
                writtenIDs: writtenIDs,
                status: status,
                message: message
            )
        }
        return PlaylistWriteResult(
            previewID: preview.id,
            accountID: activeWriteAccountID,
            status: status,
            sourceURL: preview.sourceURL,
            targetPlaylistID: targetID,
            targetPlaylistURL: targetURL ?? preview.targetPlaylistURL ?? targetID.flatMap { Self.playlistURL(id: $0, fallback: preview.sourceURL) },
            expectedTrackIDs: expectedIDs,
            writtenTrackIDs: writtenIDs,
            missingTrackIDs: missingIDs,
            observedTrackIDs: observedIDs,
            orderMatches: orderMatches,
            message: message
        )
    }

    private static func isSubsequence(_ expected: [String], in observed: [String]) -> Bool {
        guard !expected.isEmpty else { return true }
        var observedIndex = 0
        for expectedID in expected {
            guard let match = observed[observedIndex...].firstIndex(of: expectedID) else { return false }
            observedIndex = match + 1
        }
        return true
    }

    private static func playlistID(from url: URL) -> String? {
        if let queryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
           queryID.allSatisfy(\.isNumber) {
            return queryID
        }
        let pathMatch = url.path.range(of: #"playlist[/-](\d+)"#, options: .regularExpression)
        if let pathMatch {
            let value = String(url.path[pathMatch])
            return value.split(whereSeparator: { !$0.isNumber }).last.map(String.init)
        }
        let fragment = url.fragment ?? ""
        let fragmentMatch = fragment.range(of: #"playlist[^\d]*(\d+)"#, options: .regularExpression)
        if let fragmentMatch {
            let value = String(fragment[fragmentMatch])
            return value.split(whereSeparator: { !$0.isNumber }).last.map(String.init)
        }
        return nil
    }

    private static func playlistURL(id: String, fallback: URL) -> URL? {
        guard var components = URLComponents(url: fallback, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else { return nil }
        components.path = "/playlist"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        components.fragment = nil
        return components.url
    }

    private static var playlistWriteJournalURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Resonance", isDirectory: true)
            .appendingPathComponent("playlist-write-journal.json")
    }

    private func loadPlaylistWriteJournal() {
        guard let url = Self.playlistWriteJournalURL else {
            playlistJournalError = "无法确定本地 journal 路径。"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            playlistWriteJournal = try JSONDecoder().decode([PlaylistWriteJournalEntry].self, from: data)
        } catch {
            playlistWriteJournal = []
            playlistJournalError = "本地 journal 损坏或不可读：\(error.localizedDescription)"
        }
    }

    private func recordPlaylistWrite(
        preview: PlaylistWritePreview,
        accountID: String,
        targetID: String?,
        writtenIDs: [String],
        status: PlaylistWriteStatus,
        message: String
    ) throws {
        guard playlistJournalError == nil else {
            throw WebWorkspaceError.playlistJournalUnavailable(playlistJournalError ?? "本地 journal 不可用。")
        }
        let entry = PlaylistWriteJournalEntry(
            previewID: preview.id,
            accountID: accountID,
            targetPlaylistID: targetID,
            expectedTrackIDs: preview.tracks.map(\.id),
            writtenTrackIDs: writtenIDs,
            status: status,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            message: message
        )
        guard let url = Self.playlistWriteJournalURL else {
            let error = WebWorkspaceError.playlistJournalUnavailable("无法确定本地 journal 路径。")
            playlistJournalError = error.localizedDescription
            throw error
        }
        var nextEntries = playlistWriteJournal.filter { $0.previewID != preview.id }
        nextEntries.append(entry)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(nextEntries)
            try data.write(to: url, options: .atomic)
            playlistWriteJournal = nextEntries
        } catch {
            let journalError = WebWorkspaceError.playlistJournalUnavailable(error.localizedDescription)
            playlistJournalError = journalError.localizedDescription
            throw journalError
        }
    }

    private func verifyCurrentAccount(expected: String? = nil) async throws -> String {
        let result = try await runPlaylistWriter(operation: "readAccount", payload: WriterPayload())
        guard result.ok, let accountID = result.accountID, !accountID.isEmpty else {
            throw WebWorkspaceError.playlistExportUnavailable(
                result.message ?? "无法从正常页面 DOM 识别当前登录账号。"
            )
        }
        if let expected, expected != accountID {
            throw WebWorkspaceError.playlistExportUnavailable(
                "当前登录账号已变化（原账号 \(expected)，当前账号 \(accountID)），已停止写入。"
            )
        }
        return accountID
    }

    private func ensurePageReady() async throws {
        if isLoading {
            try await waitForLoad()
        }
        guard pageLoadReady, browserView.url != nil else {
            throw WebWorkspaceError.pageNotLoaded
        }
    }

    private func cancelPendingLoad(with error: Error) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        if let pendingLoad {
            self.pendingLoad = nil
            pendingLoad.resume(throwing: error)
        }
    }

    private func finishNavigation(_ result: Result<Void, Error>, generation: Int) {
        guard generation == navigationGeneration else { return }
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        isLoading = false
        switch result {
        case .success:
            pageLoadReady = true
            loadedPageURL = browserView.url
        case .failure:
            pageLoadReady = false
        }
        if let pendingLoad {
            self.pendingLoad = nil
            pendingLoad.resume(with: result)
        }
    }

    private func evaluateJSON<T: Decodable>(_ expression: String, as type: T.Type) async throws -> T {
        let wrapped = "JSON.stringify((\(expression)))"
        let value: Any?
        do {
            value = try await browserView.evaluateJavaScript(wrapped)
        } catch {
            throw WebWorkspaceError.scriptEvaluationFailed(error.localizedDescription)
        }
        guard let json = value as? String,
              let data = json.data(using: .utf8) else {
            throw WebWorkspaceError.invalidScriptResult
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WebWorkspaceError.scriptEvaluationFailed("返回 JSON 无法解码：\(error.localizedDescription)")
        }
    }

    private static func loadResourceScript(named name: String) throws -> String {
        var bundles: [Bundle] = [Bundle.main]
        if let resourceDirectory = Bundle.main.resourceURL,
           let childBundles = try? FileManager.default.contentsOfDirectory(
               at: resourceDirectory,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            bundles.append(contentsOf: childBundles
                .filter { $0.pathExtension == "bundle" }
                .compactMap { Bundle(url: $0) })
        }
        bundles.append(Bundle(for: WebWorkspace.self))
        #if SWIFT_PACKAGE
        // Bundle.module is a development fallback. The packaged app copies
        // the generated resource bundle below Contents/Resources; consulting
        // Bundle.module there can point back at a developer .build path.
        let isPackagedApp = Bundle.main.executableURL?.path.contains(".app/Contents/MacOS/") == true
        if !isPackagedApp {
            bundles.append(Bundle.module)
        }
        #endif

        for bundle in bundles {
            let urls = [
                bundle.url(forResource: name, withExtension: "js", subdirectory: "Resources"),
                bundle.url(forResource: name, withExtension: "js")
            ].compactMap { $0 }
            for url in urls {
                if let script = try? String(contentsOf: url, encoding: .utf8), !script.isEmpty {
                    return script
                }
            }
        }
        throw WebWorkspaceError.scriptResourceMissing("\(name).js")
    }

    // MARK: - WebKit navigation

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()), generation: navigationGeneration)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(
            .failure(WebWorkspaceError.navigationFailed(error.localizedDescription)),
            generation: navigationGeneration
        )
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(
            .failure(WebWorkspaceError.navigationFailed(error.localizedDescription)),
            generation: navigationGeneration
        )
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(
            .failure(WebWorkspaceError.navigationFailed("网页内容进程已终止")),
            generation: navigationGeneration
        )
    }

    // MARK: - Raw page result types

    private struct RawCurvePoint: Decodable {
        let frequencyHz: Double
        let decibels: Double
    }

    private struct RawCurve: Decodable {
        let id: String
        let chartTitle: String?
        let seriesName: String
        let curveKind: String
        let channel: String?
        let role: String?
        let points: [RawCurvePoint]
        let sourceElementID: String?
        let xAxisName: String?
        let yAxisName: String?
        let hasLogarithmicXAxis: Bool
        let extractionSource: String?
        let evidencePath: String?
        let selectable: Bool
    }

    private struct CurveEnvelope: Decodable {
        let pageURL: String?
        let extractedAt: String?
        let curves: [RawCurve]
        let warnings: [String]
    }

    private struct RawPlaylistTrack: Decodable {
        let id: String
        let name: String?
        let artists: String?
        let order: Int
        let url: String
        let sourceText: String?
    }

    private struct PlaylistEnvelope: Decodable {
        let sourceURL: String?
        let playlistID: String?
        let playlistName: String?
        let extractedAt: String?
        let tracks: [RawPlaylistTrack]
        let totalCount: Int?
        let completeness: String
        let completenessReason: String
        let warnings: [String]
    }

    private struct WriterPayload: Encodable {
        let name: String?
        let trackID: String?
        let targetPlaylistID: String?

        init(name: String? = nil, trackID: String? = nil, targetPlaylistID: String? = nil) {
            self.name = name
            self.trackID = trackID
            self.targetPlaylistID = targetPlaylistID
        }
    }

    private struct WriterPlaylistItem: Decodable {
        let id: String?
        let name: String?
    }

    private struct WriterResult: Decodable {
        let ok: Bool
        let stage: String?
        let visible: Bool?
        let message: String?
        let accountID: String?
        let accountName: String?
        let evidenceSelector: String?
        let items: [WriterPlaylistItem]?
    }
}

/// SwiftUI adapter for embedding the native web view. The controller remains
/// available to screens that need AppKit lifecycle control or direct access to
/// `browserView`.
@MainActor
public struct WebWorkspaceView: NSViewRepresentable {
    public let workspace: WebWorkspace

    public init(workspace: WebWorkspace) {
        self.workspace = workspace
    }

    public func makeNSView(context: Context) -> WKWebView {
        workspace.browserView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}

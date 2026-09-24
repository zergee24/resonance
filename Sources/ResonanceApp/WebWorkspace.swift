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
        case playlistWriteInProgress
        case pendingPlaylistWriteExists
        case playlistWriteUnavailable(String)

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
            case .playlistWriteInProgress:
                return "歌单写入仍在进行，请等待当前网页操作结束。"
            case .pendingPlaylistWriteExists:
                return "已有一次未完成的歌单写入，请先打开目标歌单核对或明确放弃后再新建。"
            case let .playlistWriteUnavailable(message):
                return message
            }
        }
    }

    /// The WKWebView is public so the host SwiftUI screen can embed the
    /// browser directly or use `WebWorkspaceView` below.
    public let browserView: WKWebView

    @Published public private(set) var curveCandidates: [CurveCandidate] = []
    @Published public private(set) var curveWarnings: [String] = []
    @Published public private(set) var playlistExtraction: PlaylistExtraction?
    @Published public private(set) var pendingPlaylistWrite: PlaylistWriteRequest?
    @Published public private(set) var loadedPageURL: URL?
    @Published public private(set) var isLoading = false

    private var pageLoadReady = false
    private var navigationGeneration = 0
    private var pendingLoad: CheckedContinuation<Void, Error>?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var playlistWriteBusy = false

    public init(configuration: WKWebViewConfiguration? = nil) {
        let webConfiguration = configuration ?? Self.makeConfiguration()
        self.browserView = WKWebView(frame: .zero, configuration: webConfiguration)
        super.init(nibName: nil, bundle: nil)

        browserView.navigationDelegate = self
        browserView.uiDelegate = self
        browserView.allowsBackForwardNavigationGestures = true
        browserView.setValue(false, forKey: "drawsBackground")
        pendingPlaylistWrite = PlaylistWriter.loadPendingRequest()
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

    /// Creates a playlist through the normal NetEase page UI and verifies the
    /// resulting playlist by reading the rendered playlist page again.
    public func writePlaylist(request: PlaylistWriteRequest) async throws -> PlaylistWriteResult {
        guard !playlistWriteBusy else {
            throw WebWorkspaceError.playlistWriteInProgress
        }
        playlistWriteBusy = true
        defer { playlistWriteBusy = false }

        do {
            let result = try await PlaylistWriter(web: self).write(request: request)
            pendingPlaylistWrite = PlaylistWriter.loadPendingRequest()
            return result
        } catch {
            pendingPlaylistWrite = PlaylistWriter.loadPendingRequest()
            throw error
        }
    }

    /// Reads a user-confirmed target playlist URL through the normal page and
    /// compares its rendered rows with the original request.
    public func checkPlaylist(
        request: PlaylistWriteRequest,
        targetURL: URL
    ) async throws -> PlaylistWriteResult {
        guard !playlistWriteBusy else {
            throw WebWorkspaceError.playlistWriteInProgress
        }
        playlistWriteBusy = true
        defer { playlistWriteBusy = false }

        do {
            let result = try await PlaylistWriter(web: self).check(request: request, targetURL: targetURL)
            pendingPlaylistWrite = PlaylistWriter.loadPendingRequest()
            return result
        } catch {
            pendingPlaylistWrite = PlaylistWriter.loadPendingRequest()
            throw error
        }
    }

    /// Explicitly forgets the local pending receipt after the user has
    /// confirmed the remote state. This never deletes or changes a playlist.
    public func dismissPendingPlaylistWrite() throws {
        guard !playlistWriteBusy else {
            throw WebWorkspaceError.playlistWriteInProgress
        }
        try PlaylistWriter.dismissPendingReceipt()
        pendingPlaylistWrite = nil
    }

    func ensurePageReady() async throws {
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

    func evaluateJSON<T: Decodable>(_ expression: String, as type: T.Type) async throws -> T {
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

    static func loadResourceScript(named name: String) throws -> String {
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

import Foundation

extension WebWorkspace {
    public enum PlaylistWriteStatus: String, Codable, Hashable, Sendable {
        case verified
        case readbackIncomplete
        case createdUnknown
        case failed
    }

    public struct PlaylistWriteRequest: Codable, Hashable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let tracks: [PlaylistTrack]

        public init(id: UUID = UUID(), name: String, tracks: [PlaylistTrack]) {
            self.id = id
            self.name = name
            self.tracks = tracks
        }
    }

    public struct PlaylistWriteResult: Codable, Hashable, Sendable {
        public let requestID: UUID
        public let status: PlaylistWriteStatus
        public let targetPlaylistURL: URL?
        public let expectedTrackIDs: [String]
        public let observedTrackIDs: [String]
        public let missingTrackIDs: [String]
        public let orderMatches: Bool?
        public let message: String

        public init(
            requestID: UUID,
            status: PlaylistWriteStatus,
            targetPlaylistURL: URL?,
            expectedTrackIDs: [String],
            observedTrackIDs: [String],
            missingTrackIDs: [String],
            orderMatches: Bool?,
            message: String
        ) {
            self.requestID = requestID
            self.status = status
            self.targetPlaylistURL = targetPlaylistURL
            self.expectedTrackIDs = expectedTrackIDs
            self.observedTrackIDs = observedTrackIDs
            self.missingTrackIDs = missingTrackIDs
            self.orderMatches = orderMatches
            self.message = message
        }
    }
}

@MainActor
final class PlaylistWriter {
    private struct Receipt: Codable {
        let request: WebWorkspace.PlaylistWriteRequest
        var targetPlaylistID: String?
        var targetPlaylistURL: URL?
        var creationSubmitted: Bool
        var status: WebWorkspace.PlaylistWriteStatus?
        var updatedAt: String
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
        let loggedIn: Bool?
        let items: [WriterPlaylistItem]?
    }

    private weak var web: WebWorkspace?

    init(web: WebWorkspace) {
        self.web = web
    }

    static func loadPendingRequest() -> WebWorkspace.PlaylistWriteRequest? {
        do {
            guard let receipt = try loadReceipt(), receipt.status != .verified else { return nil }
            return receipt.request
        } catch {
            return nil
        }
    }

    static func dismissPendingReceipt() throws {
        guard let url = receiptURL else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("无法确定本地写入凭据路径。")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("无法清除本地写入凭据：\(error.localizedDescription)")
        }
    }

    func write(request: WebWorkspace.PlaylistWriteRequest) async throws -> WebWorkspace.PlaylistWriteResult {
        guard let web else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("网页工作区已关闭。")
        }
        let request = try normalizedRequest(request)
        var receipt = try Self.loadReceipt()

        if let existing = receipt {
            if existing.request.id != request.id {
                if existing.status == .verified {
                    receipt = nil
                } else if existing.creationSubmitted || existing.targetPlaylistID != nil {
                    throw WebWorkspace.WebWorkspaceError.pendingPlaylistWriteExists
                }
            } else if existing.status == .verified, let targetURL = existing.targetPlaylistURL {
                return try await readback(request: request, targetURL: targetURL, receipt: existing)
            } else if existing.creationSubmitted {
                if let targetURL = existing.targetPlaylistURL {
                    return try await readback(request: request, targetURL: targetURL, receipt: existing)
                }
                return unknownResult(
                    request: request,
                    status: .createdUnknown,
                    targetURL: nil,
                    message: "创建提交结果未知，未找到可核验的目标歌单链接；请先在网易云页面确认后再继续。"
                )
            }
        }

        // NetEase inserts newly collected songs at the front of a playlist.
        // Create with the last requested song, then add the rest in reverse.
        let creationTrack = request.tracks[request.tracks.count - 1]
        try await web.loadAndWait(url: creationTrack.url)
        try requireNetEasePage(web)
        try await requireLoggedInHeader()

        let before = try await openPlaylistWindow(for: creationTrack)
        let beforeIDs = Set(before.items?.compactMap(\.id) ?? [])

        var newReceipt = receipt ?? Receipt(
            request: request,
            targetPlaylistID: nil,
            targetPlaylistURL: nil,
            creationSubmitted: false,
            status: nil,
            updatedAt: now()
        )
        try Self.saveReceipt(newReceipt)

        let requestCreate = try await run(operation: "requestCreate", payload: WriterPayload())
        guard requestCreate.ok else {
            return try failBeforeCreate(request: request, message: requestCreate.message ?? "当前页面没有新建歌单入口。")
        }
        if requestCreate.stage == "createDialogRequested" {
            _ = try await wait(operation: "createState", payload: WriterPayload(), timeout: 8) { $0.visible == true }
        }
        let createState = try await run(operation: "createState", payload: WriterPayload())
        guard createState.visible == true else {
            return try failBeforeCreate(request: request, message: createState.message ?? "新建歌单窗口没有出现。")
        }

        // Mark the attempt before the DOM click. If the process stops after
        // this point, a later invocation can only inspect the result.
        newReceipt.creationSubmitted = true
        newReceipt.updatedAt = now()
        try Self.saveReceipt(newReceipt)
        let submitted = try await run(operation: "submitCreate", payload: WriterPayload(name: request.name))
        guard submitted.ok, submitted.stage == "createSubmitted" else {
            if submitted.stage == "createNotSubmitted" {
                newReceipt.creationSubmitted = false
                newReceipt.updatedAt = now()
                try Self.saveReceipt(newReceipt)
                return try failBeforeCreate(request: request, message: submitted.message ?? "新建歌单尚未提交。")
            }
            return unknownResult(
                request: request,
                status: .createdUnknown,
                targetURL: nil,
                message: submitted.message ?? "新建歌单网页操作结果未知，已停止且不会重放创建。"
            )
        }

        do {
            _ = try await wait(operation: "createState", payload: WriterPayload(), timeout: 8) { $0.visible == false }
        } catch {
            return unknownResult(
                request: request,
                status: .createdUnknown,
                targetURL: nil,
                message: "新建歌单已提交，但窗口关闭结果未知；请先在网易云页面确认目标歌单。"
            )
        }

        let created = try await findCreatedPlaylist(
            request: request,
            firstTrack: creationTrack,
            beforeIDs: beforeIDs
        )
        guard let createdID = created.id else {
            return unknownResult(
                request: request,
                status: .createdUnknown,
                targetURL: nil,
                message: "新建歌单已提交，但正常页面没有返回可核验的目标歌单 ID；不会重复创建。"
            )
        }
        let targetURL = Self.playlistURL(id: createdID)
        newReceipt.targetPlaylistID = createdID
        newReceipt.targetPlaylistURL = targetURL
        newReceipt.updatedAt = now()
        try Self.saveReceipt(newReceipt)

        var alreadyPresentIDs = Set<String>()
        do {
            try await web.loadAndWait(url: targetURL)
            let snapshot = try await web.extractPlaylist()
            guard snapshot.playlistID == createdID else {
                throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("新建歌单目标页面回读 ID 不一致，已停止继续添加。")
            }
            // A normal ‘收藏到歌单’ flow may include the first song while it
            // creates the playlist. Preserve every visible ID and add only
            // tracks that are actually absent; partial DOM is never treated as
            // proof that unseen tracks are absent.
            alreadyPresentIDs = Set(snapshot.tracks.map(\.id))
        } catch {
            return try failedWriteResult(
                request: request,
                targetURL: targetURL,
                message: "目标歌单首次回读失败，已停止继续添加：\(error.localizedDescription)"
            )
        }

        for track in request.tracks.reversed() {
            if alreadyPresentIDs.contains(track.id) { continue }
            do {
                _ = try await openPlaylistWindow(for: track)
                _ = try await wait(operation: "listPlaylists", payload: WriterPayload(), timeout: 8) {
                    $0.items?.contains(where: { $0.id == createdID }) == true
                }
                let selected = try await run(
                    operation: "selectTarget",
                    payload: WriterPayload(targetPlaylistID: createdID)
                )
                guard selected.ok else {
                    return try failedWriteResult(
                        request: request,
                        targetURL: targetURL,
                        message: selected.message ?? "目标歌单未出现在当前正常页面。"
                    )
                }
                _ = try await wait(operation: "modalState", payload: WriterPayload(), timeout: 8) { $0.visible == false }
            } catch {
                return try failedWriteResult(
                    request: request,
                    targetURL: targetURL,
                    message: "歌曲 \(track.id) 的网页添加未完成：\(error.localizedDescription)"
                )
            }
        }

        newReceipt.updatedAt = now()
        try Self.saveReceipt(newReceipt)
        return try await readback(request: request, targetURL: targetURL, receipt: newReceipt)
    }

    func check(
        request: WebWorkspace.PlaylistWriteRequest,
        targetURL: URL
    ) async throws -> WebWorkspace.PlaylistWriteResult {
        guard let web else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("网页工作区已关闭。")
        }
        let request = try normalizedRequest(request)
        let targetID = try Self.requirePlaylistID(in: targetURL)
        let receipt = try Self.loadReceipt()
        if let receipt, receipt.request.id != request.id, receipt.creationSubmitted {
            throw WebWorkspace.WebWorkspaceError.pendingPlaylistWriteExists
        }
        if let receiptTargetID = receipt?.targetPlaylistID, receiptTargetID != targetID {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("目标链接与本地写入凭据不一致，已停止回读。")
        }
        try await web.ensurePageReady()
        try requireNetEasePage(web)
        return try await readback(request: request, targetURL: targetURL, receipt: receipt)
    }

    private func requireLoggedInHeader() async throws {
        let result = try await run(operation: "headerState", payload: WriterPayload())
        guard result.ok, result.loggedIn == true else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable(
                result.message ?? "请先在网易云页面顶部完成登录，确认后再创建歌单。"
            )
        }
    }

    private func openPlaylistWindow(for track: WebWorkspace.PlaylistTrack) async throws -> WriterResult {
        guard let web else { throw WebWorkspace.WebWorkspaceError.pageNotLoaded }
        var request = try await run(operation: "openAdd", payload: WriterPayload(trackID: track.id))
        if !request.ok, request.stage == "trackNotRendered" {
            try await web.loadAndWait(url: track.url)
            request = try await run(operation: "openAdd", payload: WriterPayload(trackID: track.id))
        }
        guard request.ok else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable(
                request.message ?? "当前正常页面没有该歌曲的添加入口。"
            )
        }
        _ = try await wait(operation: "modalState", payload: WriterPayload(), timeout: 8) { $0.visible == true }
        let list = try await wait(operation: "listPlaylists", payload: WriterPayload(), timeout: 8) {
            $0.ok && $0.items?.isEmpty == false
        }
        guard list.ok else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable(
                list.message ?? "当前页面没有可核验的歌单选择窗口。"
            )
        }
        return list
    }

    private func findCreatedPlaylist(
        request: WebWorkspace.PlaylistWriteRequest,
        firstTrack: WebWorkspace.PlaylistTrack,
        beforeIDs: Set<String>
    ) async throws -> WriterPlaylistItem {
        let deadline = Date().addingTimeInterval(8)
        var lastMessage: String?
        while Date() < deadline {
            try Task.checkCancellation()
            let list: WriterResult
            let modal = try await run(operation: "modalState", payload: WriterPayload())
            if modal.visible == true {
                list = try await run(operation: "listPlaylists", payload: WriterPayload())
            } else {
                list = try await openPlaylistWindow(for: firstTrack)
            }
            let candidates = (list.items ?? []).filter { item in
                guard let id = item.id else { return false }
                return !beforeIDs.contains(id) && item.name == request.name
            }
            if candidates.count > 1 {
                throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable(
                    "正常页面显示了多个同名新歌单，无法安全判断目标；请先在网易云页面确认后再核对。"
                )
            }
            if let created = candidates.first {
                return created
            }
            lastMessage = list.message
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable(
            lastMessage ?? "正常页面在规定时间内没有显示新建歌单。"
        )
    }

    private func readback(
        request: WebWorkspace.PlaylistWriteRequest,
        targetURL: URL,
        receipt: Receipt?
    ) async throws -> WebWorkspace.PlaylistWriteResult {
        guard let web else { throw WebWorkspace.WebWorkspaceError.pageNotLoaded }
        let targetID = try Self.requirePlaylistID(in: targetURL)
        try await web.loadAndWait(url: Self.playlistURL(id: targetID))
        let extraction = try await web.extractPlaylist()
        guard extraction.playlistID == targetID else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable(
                "目标页面回读的歌单 ID 与链接不一致，未宣称写入完成。"
            )
        }
        let observedIDs = extraction.tracks.map(\.id)
        let expectedIDs = request.tracks.map(\.id)
        let missingIDs = expectedIDs.filter { !observedIDs.contains($0) }
        let orderMatches = observedIDs == expectedIDs
        let verified = extraction.completeness == .complete && observedIDs == expectedIDs
        let status: WebWorkspace.PlaylistWriteStatus = verified ? .verified : .readbackIncomplete
        let message: String
        if verified {
            message = "目标歌单已通过正常页面回读，歌曲 ID、数量和顺序均已核对。"
        } else {
            var reasons: [String] = []
            if extraction.completeness != .complete { reasons.append("页面读取未完成") }
            if !missingIDs.isEmpty { reasons.append("缺少 \(missingIDs.count) 首歌曲") }
            if missingIDs.isEmpty && !orderMatches { reasons.append("歌曲数量或顺序不一致") }
            message = "目标歌单已打开，但\(reasons.joined(separator: "、"))；未宣称写入全部完成。"
        }

        let loadedReceipt = try Self.loadReceipt()
        let updatedReceipt = receipt ?? loadedReceipt
        if var updatedReceipt, updatedReceipt.request.id == request.id {
            updatedReceipt.targetPlaylistID = targetID
            updatedReceipt.targetPlaylistURL = targetURL
            updatedReceipt.status = status
            updatedReceipt.updatedAt = now()
            try Self.saveReceipt(updatedReceipt)
        }
        return WebWorkspace.PlaylistWriteResult(
            requestID: request.id,
            status: status,
            targetPlaylistURL: targetURL,
            expectedTrackIDs: expectedIDs,
            observedTrackIDs: observedIDs,
            missingTrackIDs: missingIDs,
            orderMatches: orderMatches,
            message: message
        )
    }

    private func unknownResult(
        request: WebWorkspace.PlaylistWriteRequest,
        status: WebWorkspace.PlaylistWriteStatus,
        targetURL: URL?,
        message: String
    ) -> WebWorkspace.PlaylistWriteResult {
        WebWorkspace.PlaylistWriteResult(
            requestID: request.id,
            status: status,
            targetPlaylistURL: targetURL,
            expectedTrackIDs: request.tracks.map(\.id),
            observedTrackIDs: [],
            missingTrackIDs: request.tracks.map(\.id),
            orderMatches: nil,
            message: message
        )
    }

    private func failBeforeCreate(
        request: WebWorkspace.PlaylistWriteRequest,
        message: String
    ) throws -> WebWorkspace.PlaylistWriteResult {
        try Self.removeReceipt()
        return unknownResult(request: request, status: .failed, targetURL: nil, message: message)
    }

    private func failedWriteResult(
        request: WebWorkspace.PlaylistWriteRequest,
        targetURL: URL,
        message: String
    ) throws -> WebWorkspace.PlaylistWriteResult {
        guard var receipt = try Self.loadReceipt(), receipt.request.id == request.id else {
            return unknownResult(request: request, status: .failed, targetURL: targetURL, message: message)
        }
        receipt.targetPlaylistURL = targetURL
        receipt.status = .failed
        receipt.updatedAt = now()
        try Self.saveReceipt(receipt)
        return WebWorkspace.PlaylistWriteResult(
            requestID: request.id,
            status: .failed,
            targetPlaylistURL: targetURL,
            expectedTrackIDs: request.tracks.map(\.id),
            observedTrackIDs: [],
            missingTrackIDs: request.tracks.map(\.id),
            orderMatches: nil,
            message: message
        )
    }

    private func wait(
        operation: String,
        payload: WriterPayload,
        timeout: TimeInterval,
        where predicate: (WriterResult) -> Bool
    ) async throws -> WriterResult {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var lastResult: WriterResult?
        while Date() < deadline {
            try Task.checkCancellation()
            let result = try await run(operation: operation, payload: payload)
            lastResult = result
            if predicate(result) { return result }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable(
            lastResult?.message ?? "正常网页界面在规定时间内没有进入预期状态。"
        )
    }

    private func run(operation: String, payload: WriterPayload) async throws -> WriterResult {
        guard let web else { throw WebWorkspace.WebWorkspaceError.pageNotLoaded }
        let script = try WebWorkspace.loadResourceScript(named: "playlist_writer")
        let operationJSON = String(decoding: try JSONEncoder().encode(operation), as: UTF8.self)
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        return try await web.evaluateJSON("\(script)(\(operationJSON), \(payloadJSON))", as: WriterResult.self)
    }

    private func normalizedRequest(_ request: WebWorkspace.PlaylistWriteRequest) throws -> WebWorkspace.PlaylistWriteRequest {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("歌单名称不能为空。")
        }
        guard !request.tracks.isEmpty else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("没有可写入的歌曲。")
        }
        let ids = request.tracks.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("歌曲 ID 为空或重复，已停止写入。")
        }
        for track in request.tracks {
            guard let scheme = track.url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  Self.isNetEaseHost(track.url.host) else {
                throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("歌曲链接不是网易云正常页面链接。")
            }
        }
        return WebWorkspace.PlaylistWriteRequest(id: request.id, name: name, tracks: request.tracks)
    }

    private func requireNetEasePage(_ web: WebWorkspace) throws {
        guard Self.isNetEaseHost(web.browserView.url?.host) else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("请先在内置网页打开网易云音乐页面。")
        }
    }

    private static var receiptURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Resonance", isDirectory: true)
            .appendingPathComponent("playlist-write-receipt.json")
    }

    private static func loadReceipt() throws -> Receipt? {
        guard let url = receiptURL else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("无法确定本地写入凭据路径。")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        } catch {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("本地写入凭据损坏或不可读：\(error.localizedDescription)")
        }
    }

    private static func saveReceipt(_ receipt: Receipt) throws {
        guard let url = receiptURL else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("无法确定本地写入凭据路径。")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(receipt)
            try data.write(to: url, options: .atomic)
        } catch let error as WebWorkspace.WebWorkspaceError {
            throw error
        } catch {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("本地写入凭据保存失败：\(error.localizedDescription)")
        }
    }

    private static func removeReceipt() throws {
        guard let url = receiptURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func requirePlaylistID(in url: URL) throws -> String {
        guard isNetEaseHost(url.host) else {
            throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("目标链接必须来自网易云音乐正常页面。")
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let id = components?.queryItems?.first(where: { $0.name == "id" })?.value,
           id.allSatisfy(\.isNumber), !id.isEmpty {
            return id
        }
        if let fragment = url.fragment,
           let fragmentComponents = URLComponents(string: fragment),
           let id = fragmentComponents.queryItems?.first(where: { $0.name == "id" })?.value,
           id.allSatisfy(\.isNumber), !id.isEmpty {
            return id
        }
        if let match = url.path.range(of: #"playlist[/-](\d+)"#, options: .regularExpression) {
            let value = String(url.path[match])
            if let id = value.split(whereSeparator: { !$0.isNumber }).last.map(String.init) {
                return id
            }
        }
        throw WebWorkspace.WebWorkspaceError.playlistWriteUnavailable("目标链接缺少可核验的网易云歌单 ID。")
    }

    private static func playlistURL(id: String) -> URL {
        // Use the normal document URL so WKWebView performs a navigation.
        // A hash-only route can render the target without firing didFinish.
        URL(string: "https://music.163.com/playlist?id=\(id)")!
    }

    private static func isNetEaseHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "music.163.com" || host == "www.music.163.com"
    }

    private func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

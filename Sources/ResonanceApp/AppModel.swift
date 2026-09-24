import AppKit
import AVFoundation
import Combine
import Foundation
import ResonanceCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: WorkMode = .song
    @Published var curves: [LibraryCurve] = []
    @Published var headphones: [HeadphoneEntry] = []
    @Published var tracks: [TrackEntry] = []
    @Published var playlists: [PlaylistEntry] = []
    @Published var selectedTrackID: UUID?
    @Published var selectedHeadphoneID: UUID?
    @Published var selectedPlaylistID: UUID?
    @Published var sort: SongSort = .character
    @Published var includePartial = false
    @Published var results: [MatchPresentation] = []
    @Published var selectedResultID: String?
    @Published var spectrumLine: [Double] = []
    @Published var spectrumFrequencies: [Double] = []
    @Published var status = "导入曲线和歌曲，开始建立你的声学资料库。"
    @Published var busy = false
    @Published var matching = false
    @Published var exportRevision = UUID()
    @Published var errorMessage: String?
    @Published var showLibrary = false
    @Published var showBrowser = false
    @Published var showCurveImport = false
    @Published var curveDraft: CurveDraft?
    @Published var isFollowPlaying = true
    @Published var automaticListeningEnabled: Bool
    @Published var automaticListeningStatus = "等待网易云播放"
    @Published var sharedProcessingDeclared = false
    let preferences: UserDefaults
    var automaticListeningPolicy = AutomaticListeningPolicy()
    var automaticListeningTimer: Timer?
    var automaticHistorySessionID: UUID?
    var automaticHistoryTrackID: UUID?
    var captureTrackID: UUID?
    var captureIsAutomatic = false
    var captureStartTask: Task<Void, Never>?
    var captureRequestID: UUID?
    var lastConfirmedCaptureSnapshot: PlayerSnapshot?
    var isShuttingDown = false
    var capturedProcessingDeclaration = false
    var capturedProcessID: Int32?

    let web = WebWorkspace()
    let capture = AudioCapture()
    let player = PlayerObserver()
    @Published var captureStartedAt: Date?
    var captureIdentity: PlayerSnapshot?
    var lastPlayerPosition: (TimeInterval, Date)?
    var database: LocalStore?
    var matchTask: Task<Void, Never>?
    var analysisTask: Task<Void, Never>?
    var analysisRevision: UUID?
    var disposables = Set<AnyCancellable>()

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        automaticListeningEnabled = AutomaticListeningPreference.isEnabled(in: preferences)
        do {
            let db = try LocalStore()
            database = db
            curves = try db.load(LibraryCurve.self, kind: "curves")
            headphones = try db.load(HeadphoneEntry.self, kind: "headphones")
            tracks = try db.load(TrackEntry.self, kind: "tracks")
            playlists = try db.load(PlaylistEntry.self, kind: "playlists")
            selectedTrackID = tracks.first?.id
            selectedHeadphoneID = headphones.first?.id
            Task { recompute() }
        } catch {
            database = nil
            errorMessage = error.localizedDescription
            status = "本地资料库未能打开，写入已停用。"
        }
    }

    var selectedTrack: TrackEntry? { tracks.first { $0.id == selectedTrackID } }
    var selectedHeadphone: HeadphoneEntry? { headphones.first { $0.id == selectedHeadphoneID } }
    var selectedResult: MatchPresentation? { results.first { $0.id == selectedResultID } ?? results.first }
    var references: [LibraryCurve] { curves.filter(\.isReference) }
    var analyzedCount: Int { tracks.filter(\.analyzed).count }

    func report(_ error: Error) { errorMessage = error.localizedDescription; status = error.localizedDescription }

    func saveHeadphone(_ item: HeadphoneEntry) {
        do {
            guard let database else { return }
            try database.save(item, kind: "headphones", id: item.id.uuidString)
            if let index = headphones.firstIndex(where: { $0.id == item.id }) { headphones[index] = item }
            else { headphones.append(item) }
            recompute()
        } catch { report(error) }
    }

    func saveTrack(_ item: TrackEntry) throws {
        guard let database else { throw StoreError.database("资料库不可用") }
        try database.save(item, kind: "tracks", id: item.id.uuidString)
        if let index = tracks.firstIndex(where: { $0.id == item.id }) { tracks[index] = item }
        else { tracks.append(item) }
    }

    func chooseCurveFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .data]
        panel.allowsMultipleSelection = false
        panel.message = "导入真实 Hz—dB 数值曲线；左右声道可分别导入。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let curve = try CurveImporter().load(from: url, name: url.deletingPathExtension().lastPathComponent, source: url.absoluteString, measurementSystem: "")
            curveDraft = CurveDraft(name: curve.name, frequencies: curve.points.map(\.frequencyHz), levels: curve.points.map(\.decibels), source: url.absoluteString, notes: "文件导入；测量体系与有效频段需按来源填写。")
            showCurveImport = true
        } catch { report(error) }
    }

    func chooseAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "本地分析真实音频，保留原始采样率与声道。"
        guard panel.runModal() == .OK else { return }
        analyzeFiles(panel.urls)
    }

    func analyzeFiles(_ urls: [URL]) {
        guard !busy, let database else { return }
        let previousAnalysis = analysisTask
        let revision = UUID()
        analysisRevision = revision
        busy = true
        analysisTask = Task {
            await previousAnalysis?.value
            defer { if analysisRevision == revision { busy = false } }
            for sourceURL in urls {
                if Task.isCancelled { break }
                var track = TrackEntry(title: sourceURL.deletingPathExtension().lastPathComponent, artist: "", processingState: "基于导入文件；不推断母带处理")
                let destination = database.directory.appendingPathComponent("Audio/\(track.id.uuidString).\(sourceURL.pathExtension)")
                do {
                    status = "正在分析 · \(track.title)"
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                    track.audioPath = destination.path
                    let input = try AVAudioFile(forReading: destination)
                    let duration = Double(input.length) / input.processingFormat.sampleRate
                    let coverage = try Coverage(kind: .complete, mediaDurationSeconds: duration, intervals: [TimeRange(startSeconds: 0, endSeconds: duration)], identityConfirmed: true)
                    let id = track.id
                    let analyzed = try await Task.detached(priority: .userInitiated) {
                        (try SpectrumAnalyzer().analyze(fileURL: destination, coverage: coverage, recordingID: id), try LocalStore.audioDigest(destination))
                    }.value
                    let feature = analyzed.0
                    track.contentSHA256 = analyzed.1
                    let artifactURL = database.featureURL(id: id)
                    try await Task.detached(priority: .utility) { try LocalStore.writeArtifact(feature, to: artifactURL) }.value
                    track.featurePath = artifactURL.path
                    track.duration = feature.durationSeconds
                    track.capturedSeconds = feature.durationSeconds
                    track.sampleRate = feature.sampleRate
                    track.channels = feature.channelCount
                    track.isFull = true
                    try saveTrack(track)
                    selectedTrackID = track.id
                    status = "已分析 \(track.title) · \(Int(feature.sampleRate)) Hz · \(feature.channelCount) 声道"
                } catch {
                    track.error = error.localizedDescription
                    let analysisError = error
                    do { try saveTrack(track) }
                    catch { report(error); continue }
                    report(analysisError)
                }
            }
            recompute()
        }
    }

    func saveCurveDraft(_ draft: CurveDraft, name: String, system: String, minimum: Double, maximum: Double, isReference: Bool, owned: Bool, notes: String) throws {
        guard let database else { throw StoreError.database("资料库不可用") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.database("请填写曲线名称") }
        let validated = try Curve(name: name, points: zip(draft.frequencies, draft.levels).map { try CurvePoint(frequencyHz: $0.0, decibels: $0.1) }, source: draft.source, measurementSystem: system, validMinHz: minimum, validMaxHz: maximum, isReference: isReference)
        let item = LibraryCurve(id: validated.id, name: name, frequencies: validated.points.map(\.frequencyHz), levels: validated.points.map(\.decibels), source: draft.source, measurementSystem: system.trimmingCharacters(in: .whitespacesAndNewlines), validMin: minimum, validMax: maximum, isReference: isReference, notes: notes)
        try database.save(item, kind: "curves", id: item.id.uuidString)
        curves.append(item)
        if !isReference {
            let headphone = HeadphoneEntry(name: name, curveID: item.id, owned: owned)
            try database.save(headphone, kind: "headphones", id: headphone.id.uuidString)
            headphones.append(headphone)
            selectedHeadphoneID = headphone.id
        }
        status = "已保存数值曲线 · \(name)"
        recompute()
    }

    func openWebsite(_ address: String) {
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme ?? "") else { return }
        web.load(url: url)
        showBrowser = true
    }

    func extractPageCurves() async {
        do {
            let candidates = try await web.extractCurves()
            status = "读到 \(candidates.count) 条候选曲线；请确认频响类型与来源。"
        } catch { report(error) }
    }

    func selectPageCurve(_ item: WebWorkspace.CurveCandidate) {
        guard item.curveKind == .frequencyResponse else { errorMessage = "只支持已确认的频率响应曲线。"; return }
        curveDraft = CurveDraft(name: item.seriesName, frequencies: item.points.map(\.frequencyHz), levels: item.points.map(\.decibels), source: item.sourceURL.absoluteString, notes: "页面图表：\(item.chartTitle ?? "未命名")；角色：\(item.role)；声道：\(item.channel ?? "未标记")。测量体系与有效范围仍需核对。")
        showCurveImport = true
    }

    func extractPagePlaylist() async {
        do {
            guard let database else { throw StoreError.database("资料库不可用") }
            let extraction = try await web.extractPlaylist()
            guard extraction.playlistID != nil else { status = "请打开包含准确歌单 ID 的网易云歌单详情页。"; return }
            guard !extraction.tracks.isEmpty else { status = "当前页面没有可核验的歌曲 ID；请打开歌单详情并展开列表。"; return }
            var playlist = PlaylistEntry(name: extraction.playlistName ?? "导入歌单", url: extraction.sourceURL.absoluteString, providerID: extraction.playlistID, trackIDs: [], complete: extraction.completeness == .complete, note: extraction.completenessReason)
            for row in extraction.tracks {
                let track = TrackEntry(title: row.name ?? "网易云 \(row.id)", artist: row.artists ?? "", neteaseID: row.id, sourceURL: row.url.absoluteString, source: "网易云歌单", sourcePlaylistID: playlist.id, sourceOrder: row.order)
                // A platform ID does not establish the recording/master or DSP version.
                // Keep each imported row unanalysed until its actual audio is available.
                try saveTrack(track)
                playlist.trackIDs.append(track.id)
            }
            try database.save(playlist, kind: "playlists", id: playlist.id.uuidString)
            playlists.append(playlist)
            selectedPlaylistID = playlist.id
            status = "已读取 \(playlist.trackIDs.count) 行 · \(playlist.complete ? "列表完整" : "未证明完整")"
            showBrowser = false
            mode = .headphone
            recompute()
        } catch { report(error) }
    }

    func revealData() { if let database { NSWorkspace.shared.open(database.directory) } }
}

struct CurveDraft {
    var name: String
    var frequencies: [Double]
    var levels: [Double]
    var source: String
    var notes: String
}

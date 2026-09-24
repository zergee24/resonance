import SwiftUI

/// Preview and explicit authorization screen for creating a new NetEase
/// playlist. The source playlist is only read; it is never used as the target.
struct PlaylistExportView: View {
    @ObservedObject var model: AppModel
    @Binding var preview: WebWorkspace.PlaylistWritePreview?
    @Binding var result: WebWorkspace.PlaylistWriteResult?
    let openBrowser: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var playlistName = ""
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var preparedCandidates: [ExportCandidate] = []
    @State private var errorMessage: String?
    @State private var isWorking = false

    private struct ExportCandidate: Identifiable, Hashable {
        let id: UUID
        let resultName: String
        let track: TrackEntry
        let platformID: String
        let url: URL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let preview {
                preparedView(preview)
            } else {
                selectionView
            }
            if let result { resultView(result) }
            if let journal = currentJournal {
                journalView(journal)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
            footer
        }
        .padding(26)
        .frame(width: 760, height: 650)
        .onAppear(perform: prepareCandidates)
        .onChange(of: model.results.map(\.id)) { _, _ in
            if preview == nil { prepareCandidates() }
        }
        .onChange(of: model.exportRevision) { _, _ in
            // A live recompute invalidates an unsubmitted preview. Once the
            // user has authorized a write, keep that immutable preview and
            // let the in-flight webpage operation finish against its journal.
            guard !isWorking else { return }
            preview = nil
            result = nil
            errorMessage = nil
            prepareCandidates()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(preview == nil ? "写入网易云新歌单" : "确认网易云新歌单").font(.title2.weight(.medium))
            Text("只新建目标歌单并添加预览中的精确歌曲 ID，不修改源歌单。网页登录在内置浏览器中完成。")
                .font(.callout).foregroundStyle(Palette.muted)
        }
    }

    private var selectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("新歌单名称", text: $playlistName)
                    .textFieldStyle(.roundedBorder)
                Text("\(selectedTrackIDs.count)/\(preparedCandidates.count) 首")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            if preparedCandidates.isEmpty {
                EmptyPanel(icon: "music.note.list", title: "没有可写入曲目", detail: "仅有声学适配结果且带准确网易云歌曲 ID 的曲目可进入预览。")
            } else {
                HStack {
                    Text("候选按声学结果顺序排列；缺少网易云 ID 的结果会被跳过。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("全选") { selectedTrackIDs = Set(preparedCandidates.map(\.id)) }
                    Button("清空") { selectedTrackIDs.removeAll() }
                }
                List(preparedCandidates) { candidate in
                    Toggle(isOn: Binding(
                        get: { selectedTrackIDs.contains(candidate.id) },
                        set: { checked in
                            if checked { selectedTrackIDs.insert(candidate.id) }
                            else { selectedTrackIDs.remove(candidate.id) }
                        }
                    )) {
                        HStack(spacing: 10) {
                            Text(candidate.resultName).lineLimit(1)
                            Spacer()
                            Text(candidate.track.artist.isEmpty ? "网易云 \(candidate.platformID)" : candidate.track.artist)
                                .font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: 350)
                if skippedCount > 0 {
                    Text("已跳过 \(skippedCount) 个缺少精确网易云歌曲 ID 或链接的适配结果。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let sourceURL = sourceURL {
                    Text("源页面：\(sourceURL.absoluteString)")
                        .font(.caption2).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
                } else {
                    Text("请先在内置网页打开网易云歌单或歌曲页面，才能安全建立源页面绑定。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func preparedView(_ preview: WebWorkspace.PlaylistWritePreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(preview.name, systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
                Text("\(preview.tracks.count) 首 · 精确 ID")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            Text("写入目标：新建歌单。源歌单只用于读取，当前操作不会修改它。")
                .font(.caption).foregroundStyle(Palette.accent)
            List(Array(preview.tracks.enumerated()), id: \.element.id) { index, track in
                HStack {
                    Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 26, alignment: .leading)
                    Text(track.name ?? "网易云 \(track.id)").lineLimit(1)
                    Spacer()
                    Text(track.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: 350)
            Text("源页面：\(preview.sourceURL.absoluteString)")
                .font(.caption2).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
        }
    }

    private func resultView(_ result: WebWorkspace.PlaylistWriteResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.status.displayName).font(.headline)
                Spacer()
                Text("完成 \(result.writtenTrackIDs.count)/\(result.expectedTrackIDs.count) 首")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            Text(result.message).font(.caption).foregroundStyle(Palette.muted)
            if let target = result.targetPlaylistURL {
                Text("目标歌单：\(target.absoluteString)").font(.caption2).textSelection(.enabled)
            }
            if !result.missingTrackIDs.isEmpty {
                Text("未核对到：\(result.missingTrackIDs.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
    }

    private func journalView(_ journal: WebWorkspace.PlaylistWriteJournalEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Palette.accent)
            Text("本地 journal：\(journal.status.displayName) · \(journal.writtenTrackIDs.count)/\(journal.expectedTrackIDs.count) 首")
                .font(.caption).foregroundStyle(Palette.muted)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button("导出本地 JSON") { model.exportCandidatePlaylist() }
            Button("在内置网页打开 / 登录") {
                guard preview != nil else {
                    errorMessage = "请先准备预览，再打开对应网易云源页面。"
                    return
                }
                openBrowser()
                dismiss()
            }
            Spacer()
            if preview != nil {
                Button("返回调整") {
                    result = nil
                    preview = nil
                    prepareCandidates()
                }
            } else {
                Button("取消") { dismiss() }
            }
            if preview == nil {
                Button("准备预览") { preparePreview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTrackIDs.isEmpty || playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceURL == nil)
            } else {
                Button {
                    executeWrite()
                } label: {
                    if isWorking { ProgressView().controlSize(.small) }
                    else { Text("确认并写入") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
    }

    private var sourceURL: URL? {
        let selectedPlaylist = model.playlists.first { $0.id == model.selectedPlaylistID }
        let playlistURL = selectedPlaylist.flatMap { URL(string: $0.url) }
        let candidate = playlistURL ?? model.web.loadedPageURL
        guard let candidate,
              let host = candidate.host?.lowercased(),
              host == "music.163.com" || host.hasSuffix(".music.163.com") else { return nil }
        let pathAndFragment = "\(candidate.path) \(candidate.fragment ?? "")"
        let normalized = pathAndFragment.lowercased()
        guard (normalized.contains("playlist") || normalized.contains("song")),
              normalized.contains("id=") else { return nil }
        return candidate
    }

    private var currentJournal: WebWorkspace.PlaylistWriteJournalEntry? {
        guard let preview else { return nil }
        return model.web.playlistWriteJournal.first(where: { $0.previewID == preview.id })
    }

    private var skippedCount: Int {
        let eligible = model.results.filter(\.eligible).count
        return max(0, eligible - preparedCandidates.count)
    }

    private func prepareCandidates() {
        var seenIDs = Set<String>()
        var values: [ExportCandidate] = []
        for result in model.results where result.eligible {
            guard let track = model.tracks.first(where: { $0.id == result.trackID }),
                  let platformID = track.neteaseID,
                  platformID.allSatisfy(\.isNumber),
                  let url = exactTrackURL(track, id: platformID) else { continue }
            guard seenIDs.insert(platformID).inserted else { continue }
            values.append(ExportCandidate(id: track.id, resultName: result.name, track: track, platformID: platformID, url: url))
        }
        preparedCandidates = values
        selectedTrackIDs.formIntersection(Set(values.map(\.id)))
        if selectedTrackIDs.isEmpty { selectedTrackIDs = Set(values.map(\.id)) }
        if playlistName.isEmpty {
            playlistName = "\(model.selectedHeadphone?.name ?? "共鸣") · \(model.sort.rawValue)"
        }
    }

    private func exactTrackURL(_ track: TrackEntry, id: String) -> URL? {
        if let source = track.sourceURL,
           let url = URL(string: source),
           neteaseTrackID(from: source) == id {
            return url
        }
        return URL(string: "https://music.163.com/song?id=\(id)")
    }

    private func preparePreview() {
        guard let sourceURL else {
            errorMessage = "源页面必须是 music.163.com 的歌单或歌曲页面，不能把毁 HiFi 页面当作歌单来源。"
            return
        }
        let chosen = preparedCandidates.filter { selectedTrackIDs.contains($0.id) }
        let rows = chosen.enumerated().map { index, item in
            WebWorkspace.PlaylistTrack(
                id: item.platformID,
                name: item.track.title,
                artists: item.track.artist.isEmpty ? nil : item.track.artist,
                order: index,
                url: item.url,
                sourceText: nil
            )
        }
        do {
            preview = try model.web.makePlaylistWritePreview(
                name: playlistName,
                tracks: rows,
                sourceURL: sourceURL,
                targetPlaylistURL: nil
            )
            result = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func executeWrite() {
        guard let preview else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                result = try await model.web.exportPlaylistThroughNormalUI(preview: preview, authorized: true)
                model.status = result?.message ?? "网易云写入完成"
            } catch {
                errorMessage = error.localizedDescription
                model.status = error.localizedDescription
            }
        }
    }
}

private extension WebWorkspace.PlaylistWriteStatus {
    var displayName: String {
        switch self {
        case .started: return "准备写入"
        case .verified: return "已写入并核对"
        case .partiallyWritten: return "部分写入"
        case .createdUnknown: return "新建结果待确认"
        case .readbackIncomplete: return "已写入但回读不完整"
        case .failed: return "写入失败"
        }
    }
}

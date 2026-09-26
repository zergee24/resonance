import SwiftUI

struct PlaylistExportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: WebWorkspace
    @State private var name = ""
    @State private var candidates: [WebWorkspace.PlaylistTrack] = []
    @State private var selected: Set<String> = []
    @State private var request: WebWorkspace.PlaylistWriteRequest?
    @State private var result: WebWorkspace.PlaylistWriteResult?
    @State private var skipped = 0
    @State private var working = false
    @State private var showBrowser = false
    @State private var error: String?
    @State private var targetAddress = ""
    @State private var confirmNewAttempt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("生成网易云歌单").font(Typography.title)
                Spacer()
                Button("关闭") { dismiss() }.disabled(working)
            }
            Text("选择歌曲并确认名称，应用会在网易云网页账号下新建歌单。桌面客户端用于听歌和采集，网页登录用于创建歌单。")
                .font(Typography.secondary).foregroundStyle(Palette.muted)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("歌单名称", text: $name).textFieldStyle(.roundedBorder).disabled(request != nil)
                    if candidates.isEmpty {
                        Text("尚无关联网易云歌曲的分析结果。可在资料库为录音绑定歌曲链接，或关联到已导入歌单。")
                            .font(Typography.secondary).foregroundStyle(Palette.muted)
                    }
                    List(candidates) { track in
                        Toggle(isOn: Binding(get: { selected.contains(track.id) }, set: { checked in
                            if checked { selected.insert(track.id) } else { selected.remove(track.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.name ?? "网易云 \(track.id)")
                                Text(track.artists ?? "ID \(track.id)").font(Typography.secondary).foregroundStyle(Palette.muted)
                            }
                        }.disabled(request != nil)
                    }.frame(minHeight: 220, idealHeight: 360)
                    if skipped > 0 {
                        Text("\(skipped) 条结果尚未关联网易云歌曲，可先在资料库绑定。")
                            .font(Typography.secondary).foregroundStyle(Palette.muted)
                    }
                    Text("预览保留本次选择的顺序；写入后会核对歌曲和顺序。")
                        .font(Typography.secondary).foregroundStyle(Palette.muted)
                }.frame(minWidth: 440, idealWidth: 460)
                if showBrowser {
                    WebWorkspaceView(workspace: workspace)
                        .frame(minWidth: 660, idealWidth: 760).frame(minHeight: 420)
                        .allowsHitTesting(!working)
                }
            }
            if let result {
                Text(result.message).font(Typography.secondary).textSelection(.enabled)
                HStack {
                    Text("已核对 \(result.expectedTrackIDs.count - result.missingTrackIDs.count) / \(result.expectedTrackIDs.count) 首")
                    if let target = result.targetPlaylistURL {
                        Button("查看网易云歌单") { openPage(target) }.disabled(working)
                    }
                }.font(Typography.secondary)
            }
            if workspace.pendingPlaylistWrite != nil && !working {
                VStack(alignment: .leading, spacing: 10) {
                    Text("上次创建尚未完全核对。可查看网易云，粘贴已创建的歌单链接重新核对。")
                        .font(Typography.secondary).foregroundStyle(.orange)
                    TextField("https://music.163.com/playlist?id=…", text: $targetAddress)
                    HStack {
                        Spacer()
                        Button("核对该歌单") { verifyTarget() }.disabled(targetAddress.isEmpty || request == nil)
                        Button("已人工核对，开始新的创建") { confirmNewAttempt = true }
                    }
                }
            }
            if let error { Text(error).font(Typography.secondary).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("连接网易云网页账号") { openPage(URL(string: "https://music.163.com/my/")!) }
                    .disabled(working)
                Spacer()
                if working { ProgressView(); Text("正在创建并核对…").font(Typography.secondary) }
                else if request == nil {
                    Button("创建网易云歌单") { write() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if workspace.pendingPlaylistWrite != nil {
                    Button("重新核对结果") { write() }.disabled(working)
                } else if result?.status == .verified {
                    Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
                } else {
                    Button("重试") { write() }
                    Button("调整预览") { request = nil; result = nil }
                }
            }
        }
        .padding(28).frame(minWidth: 760)
        .font(Typography.body)
        .controlSize(.large)
        .interactiveDismissDisabled(working)
        .onAppear { prepare() }
        .alert("确认开始新的创建？", isPresented: $confirmNewAttempt) {
            Button("取消", role: .cancel) {}
            Button("我已核对，开始新的创建") {
                do {
                    try workspace.dismissPendingPlaylistWrite()
                    request = nil; result = nil; error = nil
                    prepare()
                } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("之前的歌单可能已经创建。此操作只清除本地待核对记录；请先在网易云确认，避免重复创建。")
        }
    }

    private func prepare() {
        if let pending = workspace.pendingPlaylistWrite {
            request = pending; name = pending.name; candidates = pending.tracks
            selected = Set(pending.tracks.map(\.id))
            return
        }
        guard request == nil else { return }
        name = "\(model.selectedHeadphone?.name ?? "共鸣") · 适配歌单"
        var seen: Set<String> = []
        skipped = 0
        candidates = model.results.filter(\.eligible).compactMap { result in
            guard let track = model.tracks.first(where: { $0.id == result.trackID }),
                  let id = track.neteaseID, !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let url = URL(string: "https://music.163.com/song?id=\(id)") else {
                skipped += 1; return nil
            }
            guard seen.insert(id).inserted else { return nil }
            return WebWorkspace.PlaylistTrack(id: id, name: track.title, artists: track.artist,
                order: seen.count - 1, url: url, sourceText: nil)
        }
        selected = Set(candidates.map(\.id))
    }

    private func openPage(_ url: URL) {
        showBrowser = true
        workspace.load(url: url)
    }

    private func write() {
        let value = request ?? WebWorkspace.PlaylistWriteRequest(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            tracks: candidates.filter { selected.contains($0.id) })
        request = value; working = true; error = nil; showBrowser = true
        Task { @MainActor in
            defer { working = false }
            do { result = try await workspace.writePlaylist(request: value) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func verifyTarget() {
        guard let request, let url = URL(string: targetAddress.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        working = true; error = nil; showBrowser = true
        Task { @MainActor in
            defer { working = false }
            do { result = try await workspace.checkPlaylist(request: request, targetURL: url) }
            catch { self.error = error.localizedDescription }
        }
    }
}

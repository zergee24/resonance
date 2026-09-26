import SwiftUI
import WebKit

struct LibraryScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) { Text("声学资料库").font(Typography.title); Text("保存你的耳机曲线、参考和歌曲。").font(Typography.secondary).foregroundStyle(Palette.muted) }
                    Spacer()
                    Button("使用拉斐尔示例") { model.loadRaphaelSample() }
                    Button("导入曲线") { model.chooseCurveFile() }
                    Button("数据目录", systemImage: "folder") { model.revealData() }
                }
                SectionCaption(title: "我的耳机", trailing: "\(model.headphones.count) PROFILES")
                if model.headphones.isEmpty { EmptyPanel(icon: "headphones", title: "添加第一副耳机", detail: "从毁 HiFi 查询数值曲线，或导入已有 CSV / TXT 实测文件。") }
                ForEach(model.headphones) { item in
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Image(systemName: "headphones").font(Typography.heading).foregroundStyle(Palette.accent)
                            Text(item.name).font(Typography.heading)
                            Spacer()
                            Toggle("我拥有", isOn: Binding(get: { item.owned }, set: { var changed = item; changed.owned = $0; model.saveHeadphone(changed) })).toggleStyle(.checkbox)
                        }
                        if let curve = model.curves.first(where: { $0.id == item.curveID }) {
                            HStack {
                                TinyBadge(text: curve.measurementSystem.isEmpty ? "测量体系待核对" : curve.measurementSystem, color: curve.measurementSystem.isEmpty ? .orange : Palette.muted)
                                TinyBadge(text: "\(frequencyLabel(curve.validMin))–\(frequencyLabel(curve.validMax)) Hz")
                                Text("\(curve.frequencies.count) 个数值点").font(Typography.secondary).foregroundStyle(Palette.muted)
                            }
                            Picker("参考曲线", selection: Binding(get: { item.referenceID }, set: { var changed = item; changed.referenceID = $0; model.saveHeadphone(changed) })) {
                                Text("未关联 · 暂不能评估").tag(UUID?.none)
                                ForEach(model.references) { reference in Text("\(reference.name) · \(reference.measurementSystem.isEmpty ? "体系未知" : reference.measurementSystem)").tag(Optional(reference.id)) }
                            }
                            let ref = model.curves.first(where: { $0.id == item.referenceID })
                            let values = curve.levels + (ref?.levels ?? [])
                            let low = floor((values.min() ?? -30) / 10) * 10 - 5
                            let high = ceil((values.max() ?? 30) / 10) * 10 + 5
                            FrequencyPlot(lines: [PlotLine(id: "headphone", values: Array(zip(curve.frequencies, curve.levels)), color: Palette.accent)] + (ref.map { [PlotLine(id: "reference", values: Array(zip($0.frequencies, $0.levels)), color: .orange)] } ?? []), minDB: low, maxDB: max(low + 10, high)).frame(height: 190)
                            Text("绿色：耳机实测；橙色：所选参考。").font(Typography.secondary).foregroundStyle(Palette.muted)
                            Text(curve.notes).font(Typography.secondary).foregroundStyle(Palette.muted).textSelection(.enabled)
                            Text(curve.source).font(Typography.mono).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
                        }
                    }.padding(20).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                SectionCaption(title: "参考曲线", trailing: "\(model.references.count) REFERENCES")
                ForEach(model.references) { reference in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: reference.isPreferred == true ? "heart.fill" : "scope")
                                .foregroundStyle(reference.isPreferred == true ? Palette.accent : .orange)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(reference.name).font(Typography.secondary.weight(.medium))
                                    if reference.isPreferred == true { TinyBadge(text: "偏好参考", color: Palette.accent) }
                                }
                                HStack(spacing: 8) {
                                    TinyBadge(text: "\(frequencyLabel(reference.validMin))–\(frequencyLabel(reference.validMax)) Hz")
                                    TinyBadge(text: reference.measurementSystem.isEmpty ? "体系未确认" : reference.measurementSystem, color: reference.measurementSystem.isEmpty ? .orange : Palette.muted)
                                }
                                Text(referenceSourceLabel(reference.source)).font(Typography.mono).foregroundStyle(Palette.muted).lineLimit(2).truncationMode(.middle)
                                if !reference.notes.isEmpty { Text(reference.notes).font(Typography.secondary).foregroundStyle(Palette.muted).lineLimit(3) }
                            }
                            Spacer(minLength: 12)
                        }
                        Toggle("我喜欢的声音", isOn: Binding(
                            get: { reference.isPreferred == true },
                            set: { model.setReferencePreferred(reference.id, preferred: $0) }
                        )).toggleStyle(.checkbox).font(Typography.body)
                    }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                }
                if model.references.isEmpty { Text("导入你想比较的参考曲线。拉斐尔示例附带平直计算基线，可随时更换。").font(Typography.secondary).foregroundStyle(Palette.muted) }
                SectionCaption(title: "录音与来源", trailing: "\(model.tracks.count) ITEMS")
                ForEach(model.tracks) { track in TrackLibraryRow(track: track) }
            }.padding(30)
        }
        .font(Typography.body)
        .controlSize(.large)
    }
}

private func referenceSourceLabel(_ value: String) -> String {
    guard let url = URL(string: value), let host = url.host, !host.isEmpty else {
        return value.isEmpty ? "来源未填写" : value
    }
    return host + (url.path.isEmpty ? "" : url.path)
}

struct TrackLibraryRow: View {
    @EnvironmentObject var model: AppModel
    let track: TrackEntry
    @State private var bindingURL = ""
    @State private var showBinding = false
    @State private var showPlaylistBinding = false
    @State private var identityConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: track.analyzed ? "waveform" : "clock").foregroundStyle(track.analyzed ? Palette.accent : .orange)
                VStack(alignment: .leading, spacing: 4) { Text(track.title).font(Typography.body); Text(track.artist.isEmpty ? track.source : track.artist).font(Typography.secondary).foregroundStyle(Palette.muted) }
                Spacer()
                TinyBadge(text: track.audioPath == nil ? "仅歌曲信息" : (track.analyzed ? track.coverageLabel : "音频待分析"))
            }
            HStack(spacing: 8) {
                if let id = track.neteaseID { TinyBadge(text: "网易云 \(id)") }
                Spacer()
                if track.analyzed && track.sourcePlaylistID == nil { Button("用于歌单曲目") { showPlaylistBinding = true }.font(Typography.body) }
                Button(track.neteaseID == nil ? "绑定歌曲链接" : "查看绑定") { bindingURL = track.neteaseID.map { "https://music.163.com/song?id=\($0)" } ?? ""; identityConfirmed = false; showBinding.toggle() }.font(Typography.body)
            }
            if let application = track.sourceApplicationName?.trimmingCharacters(in: .whitespacesAndNewlines), !application.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "app.badge")
                        Text("来源：\(application)")
                    }
                    if let bundleID = track.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
                        Text(bundleID).font(Typography.mono).lineLimit(1).truncationMode(.middle).help("来源 Bundle ID")
                    }
                }.font(Typography.secondary).foregroundStyle(Palette.muted)
            } else if let bundleID = track.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "app.badge")
                    Text("来源 Bundle：\(bundleID)").font(Typography.mono).lineLimit(2).truncationMode(.middle)
                }.font(Typography.secondary).foregroundStyle(Palette.muted)
            }
            if showBinding {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("对应录音的网易云歌曲链接", text: $bindingURL)
                    HStack {
                        Spacer()
                        Button("确认绑定") {
                            guard let id = neteaseTrackID(from: bindingURL) else { model.errorMessage = "请输入包含准确歌曲 ID 的 music.163.com/song 链接。"; return }
                            var changed = track; changed.neteaseID = id; changed.sourceURL = bindingURL
                            do { try model.saveTrack(changed); model.recompute(); showBinding = false } catch { model.report(error) }
                        }.disabled(!identityConfirmed || track.sourcePlaylistID != nil).font(Typography.body)
                    }
                }
                if let existing = track.neteaseID { Text("原绑定 ID：\(existing)").font(Typography.mono).foregroundStyle(Palette.muted) }
                if track.sourcePlaylistID == nil {
                    Toggle("我确认新链接对应这段录音的歌曲与版本", isOn: $identityConfirmed).toggleStyle(.checkbox).font(Typography.body)
                } else { Text("歌单原始行的歌曲 ID 保持不变；请通过“用于歌单曲目”关联对应录音。").font(Typography.secondary).foregroundStyle(.orange) }
                Text("这是你对录音版本的手动绑定，不会把同名歌曲自动合并。").font(Typography.secondary).foregroundStyle(Palette.muted)
            }
            if let notes = track.analysisNotes, !notes.isEmpty {
                Text(notes.joined(separator: "；")).font(Typography.secondary).foregroundStyle(Palette.muted)
            }
            if let error = track.error { Text(error).font(Typography.secondary).foregroundStyle(.orange) }
        }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
            .font(Typography.body)
            .controlSize(.large)
            .sheet(isPresented: $showPlaylistBinding) { RecordingBindingView(recording: track).environmentObject(model) }
    }
}

struct CurveImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let draft: CurveDraft
    @State private var name = ""
    @State private var system = ""
    @State private var minimum = "20"
    @State private var maximum = "20000"
    @State private var reference = false
    @State private var owned = false
    @State private var notes = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("保存数值曲线").font(Typography.title.weight(.medium))
            Text("\(draft.frequencies.count) 个测量点 · 下方可补充测量信息。").font(Typography.secondary).foregroundStyle(Palette.muted)
            Form {
                TextField("名称", text: $name)
                TextField("测量体系 / 耦合器", text: $system, prompt: Text("选填，例如测量设备或来源站点"))
                HStack { TextField("有效下限 Hz", text: $minimum); TextField("有效上限 Hz", text: $maximum) }
                Toggle("这是参考目标曲线", isOn: $reference)
                if !reference { Toggle("我拥有这副耳机", isOn: $owned) }
                TextField("测量条件 / 来源备注", text: $notes, axis: .vertical).lineLimit(3...5)
            }.formStyle(.grouped)
            Text(draft.source).font(Typography.mono).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
            if let error { Text(error).font(Typography.secondary).foregroundStyle(.orange) }
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("保存到资料库") {
                    guard let low = Double(minimum), let high = Double(maximum) else { error = "上下限需要是 Hz 数值。"; return }
                    do { try model.saveCurveDraft(draft, name: name, system: system, minimum: low, maximum: high, isReference: reference, owned: owned, notes: notes); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(30).frame(minWidth: 760)
            .font(Typography.body)
            .controlSize(.large)
            .onAppear {
                name = draft.name
                notes = draft.notes
                // Keep a lossless Double round-trip. Formatting with %g can
                // round an imported upper bound such as 19896.964… to 19897,
                // which then falls outside the actual curve's valid range.
                minimum = String(draft.frequencies.min() ?? 20)
                maximum = String(draft.frequencies.max() ?? 20_000)
            }
    }
}

struct BrowserScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View { BrowserContents(workspace: model.web).environmentObject(model) }
}

struct BrowserContents: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var workspace: WebWorkspace
    @State private var address = ""
    @State private var reading = false
    @State private var showCandidates = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { workspace.browserView.goBack() } label: { Image(systemName: "chevron.left") }.help("网页后退")
                TextField("毁 HiFi 或网易云歌单地址", text: $address).textFieldStyle(.roundedBorder).onSubmit { model.openWebsite(address) }
                Button("打开") { model.openWebsite(address) }
                if workspace.isLoading || reading { ProgressView().controlSize(.small) }
                Button("读取曲线") { reading = true; Task { await model.extractPageCurves(); reading = false; showCandidates = true } }
                Button("读取歌单") { reading = true; Task { await model.extractPagePlaylist(); reading = false } }
            }.padding(16)
            HStack {
                Text("应用内正常网页 · 登录只保存在本机 WebView").font(Typography.secondary).foregroundStyle(Palette.muted)
                Spacer(); Button("搜索拉斐尔") { model.openWebsite("https://huihifi.com/search?keyword=%E6%8B%89%E6%96%90%E5%B0%94") }.font(Typography.body)
            }.padding(.horizontal, 18).padding(.bottom, 12)
            WebWorkspaceView(workspace: workspace)
            if showCandidates {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("页面数值候选 · \(workspace.curveCandidates.count) 条").font(Typography.heading); Spacer(); Button("收起") { showCandidates = false } }
                    if workspace.curveCandidates.isEmpty { Text(workspace.curveWarnings.joined(separator: "；")).font(Typography.secondary).foregroundStyle(.orange) }
                    ScrollView {
                        ForEach(workspace.curveCandidates) { item in
                            HStack {
                                VStack(alignment: .leading) { Text(item.seriesName).font(Typography.body); Text("\(item.chartTitle ?? "未标明图表类型") · \(item.curveKind.rawValue) · \(item.points.count) 点").font(Typography.secondary).foregroundStyle(Palette.muted) }
                                Spacer()
                                Button("核对并导入") { model.selectPageCurve(item) }.disabled(!item.isSelectable || item.curveKind != .frequencyResponse)
                            }.padding(.vertical, 5)
                        }
                    }.frame(maxHeight: 260)
                }.padding(18).background(Palette.panel)
            }
        }
        .font(Typography.body)
        .controlSize(.large)
        .onAppear { address = workspace.loadedPageURL?.absoluteString ?? "https://huihifi.com/home" }
        .onChange(of: workspace.loadedPageURL) { _, value in address = value?.absoluteString ?? address }
    }
}

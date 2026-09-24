import SwiftUI
import WebKit

struct LibraryScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) { Text("声学资料库").font(.system(size: 27, weight: .medium)); Text("每条曲线都有来源，每次计算可以复核。").font(.callout).foregroundStyle(Palette.muted) }
                    Spacer()
                    Button("导入曲线") { model.chooseCurveFile() }
                    Button("数据目录", systemImage: "folder") { model.revealData() }
                }
                SectionCaption(title: "我的耳机", trailing: "\(model.headphones.count) PROFILES")
                if model.headphones.isEmpty { EmptyPanel(icon: "headphones", title: "添加第一副耳机", detail: "从毁 HiFi 查询数值曲线，或导入已有 CSV / TXT 实测文件。") }
                ForEach(model.headphones) { item in
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Image(systemName: "headphones").font(.title2).foregroundStyle(Palette.accent)
                            Text(item.name).font(.headline)
                            Spacer()
                            Toggle("我拥有", isOn: Binding(get: { item.owned }, set: { var changed = item; changed.owned = $0; model.saveHeadphone(changed) })).toggleStyle(.checkbox)
                        }
                        if let curve = model.curves.first(where: { $0.id == item.curveID }) {
                            HStack {
                                TinyBadge(text: curve.measurementSystem.isEmpty ? "测量体系待核对" : curve.measurementSystem, color: curve.measurementSystem.isEmpty ? .orange : Palette.muted)
                                TinyBadge(text: "\(frequencyLabel(curve.validMin))–\(frequencyLabel(curve.validMax)) Hz")
                                Text("\(curve.frequencies.count) 个数值点").font(.caption).foregroundStyle(Palette.muted)
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
                            Text("原始数值（dB）· 绿色：实测；橙色：参考。图示位置不代表适配排名。").font(.caption2).foregroundStyle(Palette.muted)
                            Text(curve.notes).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
                            Text(curve.source).font(.caption2).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
                        }
                    }.padding(20).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                SectionCaption(title: "参考曲线", trailing: "\(model.references.count) REFERENCES")
                ForEach(model.references) { reference in
                    HStack { Image(systemName: "scope").foregroundStyle(.orange); Text(reference.name); Spacer(); Text(reference.measurementSystem.isEmpty ? "体系未确认" : reference.measurementSystem).foregroundStyle(Palette.muted) }.font(.callout).padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                }
                if model.references.isEmpty { Text("导入参考文件时选择“参考目标”。只允许与相同测量体系的耳机曲线共同计算。").font(.callout).foregroundStyle(Palette.muted) }
                SectionCaption(title: "录音与来源", trailing: "\(model.tracks.count) ITEMS")
                ForEach(model.tracks) { track in TrackLibraryRow(track: track) }
            }.padding(30)
        }
    }
}

struct TrackLibraryRow: View {
    @EnvironmentObject var model: AppModel
    let track: TrackEntry
    @State private var bindingURL = ""
    @State private var showBinding = false
    @State private var showPlaylistBinding = false
    @State private var identityConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: track.analyzed ? "waveform" : "clock").foregroundStyle(track.analyzed ? Palette.accent : .orange)
                VStack(alignment: .leading) { Text(track.title).font(.callout); Text(track.artist.isEmpty ? track.source : track.artist).font(.caption).foregroundStyle(Palette.muted) }
                Spacer()
                TinyBadge(text: track.analyzed ? track.coverageLabel : "待采集")
                if let id = track.neteaseID { TinyBadge(text: "网易云 \(id)") }
                if track.analyzed && track.sourcePlaylistID == nil { Button("用于歌单曲目") { showPlaylistBinding = true }.font(.caption) }
                Button(track.neteaseID == nil ? "绑定歌曲链接" : "查看绑定") { bindingURL = track.neteaseID.map { "https://music.163.com/song?id=\($0)" } ?? ""; identityConfirmed = false; showBinding.toggle() }.font(.caption)
            }
            if showBinding {
                HStack {
                    TextField("对应录音的网易云歌曲链接", text: $bindingURL)
                    Button("确认绑定") {
                        guard let id = neteaseTrackID(from: bindingURL) else { model.errorMessage = "请输入包含准确歌曲 ID 的 music.163.com/song 链接。"; return }
                        var changed = track; changed.neteaseID = id; changed.sourceURL = bindingURL
                        do { try model.saveTrack(changed); model.recompute(); showBinding = false } catch { model.report(error) }
                    }.disabled(!identityConfirmed || track.sourcePlaylistID != nil)
                }
                if let existing = track.neteaseID { Text("原绑定 ID：\(existing)").font(.caption).foregroundStyle(Palette.muted) }
                if track.sourcePlaylistID == nil {
                    Toggle("我确认新链接对应这段录音的歌曲与版本", isOn: $identityConfirmed).toggleStyle(.checkbox).font(.caption)
                } else { Text("歌单原始行的歌曲 ID 保持不变；请通过“用于歌单曲目”关联对应录音。").font(.caption).foregroundStyle(.orange) }
                Text("这是你对录音版本的手动绑定，不会把同名歌曲自动合并。").font(.caption2).foregroundStyle(Palette.muted)
            }
            if let error = track.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(15).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
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
            Text("保存数值曲线").font(.title2.weight(.medium))
            Text("\(draft.frequencies.count) 个测量点 · 有效频段请按测量来源填写，不能仅以图表横轴推定。").font(.callout).foregroundStyle(Palette.muted)
            Form {
                TextField("名称", text: $name)
                TextField("测量体系 / 耦合器", text: $system, prompt: Text("未知可留空，但暂不参与匹配"))
                HStack { TextField("有效下限 Hz", text: $minimum); TextField("有效上限 Hz", text: $maximum) }
                Toggle("这是参考目标曲线", isOn: $reference)
                if !reference { Toggle("我拥有这副耳机", isOn: $owned) }
                TextField("测量条件 / 来源备注", text: $notes, axis: .vertical).lineLimit(3...5)
            }.formStyle(.grouped)
            Text(draft.source).font(.caption).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("保存到资料库") {
                    guard let low = Double(minimum), let high = Double(maximum) else { error = "上下限需要是 Hz 数值。"; return }
                    do { try model.saveCurveDraft(draft, name: name, system: system, minimum: low, maximum: high, isReference: reference, owned: owned, notes: notes); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 650)
            .onAppear { name = draft.name; notes = draft.notes; minimum = String(format: "%g", draft.frequencies.min() ?? 20); maximum = String(format: "%g", draft.frequencies.max() ?? 20_000) }
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
                Text("应用内正常网页 · 登录只保存在本机 WebView").font(.caption).foregroundStyle(Palette.muted)
                Spacer(); Button("搜索拉斐尔") { model.openWebsite("https://huihifi.com/search?keyword=%E6%8B%89%E6%96%90%E5%B0%94") }.font(.caption)
            }.padding(.horizontal, 18).padding(.bottom, 12)
            WebWorkspaceView(workspace: workspace)
            if showCandidates {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("页面数值候选 · \(workspace.curveCandidates.count) 条").font(.headline); Spacer(); Button("收起") { showCandidates = false } }
                    if workspace.curveCandidates.isEmpty { Text(workspace.curveWarnings.joined(separator: "；")).font(.callout).foregroundStyle(.orange) }
                    ScrollView {
                        ForEach(workspace.curveCandidates) { item in
                            HStack {
                                VStack(alignment: .leading) { Text(item.seriesName); Text("\(item.chartTitle ?? "未标明图表类型") · \(item.curveKind.rawValue) · \(item.points.count) 点").font(.caption).foregroundStyle(Palette.muted) }
                                Spacer()
                                Button("核对并导入") { model.selectPageCurve(item) }.disabled(!item.isSelectable || item.curveKind != .frequencyResponse)
                            }.padding(.vertical, 5)
                        }
                    }.frame(maxHeight: 160)
                }.padding(18).background(Palette.panel)
            }
        }
        .onAppear { address = workspace.loadedPageURL?.absoluteString ?? "https://huihifi.com/home" }
        .onChange(of: workspace.loadedPageURL) { _, value in address = value?.absoluteString ?? address }
    }
}

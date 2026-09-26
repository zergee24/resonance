import SwiftUI
import AppKit

@main
struct ResonanceApplication: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("共鸣 · AI 歌单") {
            MainView().environmentObject(model).preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    delegate.model = model
                    model.startListeningServices()
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入音频…") { model.chooseAudioFiles() }.keyboardShortcut("o")
                Button("导入频响…") { model.chooseCurveFile() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.prepareToQuit()
        Task { @MainActor in
            await model.captureStartTask?.value
            await model.analysisTask?.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPlaylistExport = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.25)
            VStack(spacing: 0) {
                if model.showBrowser { BrowserScreen() }
                else if model.showLibrary { LibraryScreen() }
                else { workspace }
                Divider().opacity(0.2)
                HStack(spacing: 9) {
                    if model.busy || model.matching { ProgressView().controlSize(.small) }
                    else { Circle().fill(Palette.accent.opacity(0.7)).frame(width: 5, height: 5) }
                    Text(model.status).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    Spacer()
                    Text("LOCAL AUDIO").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted.opacity(0.55))
                }.padding(.horizontal, 24).frame(height: 44)
            }
        }
        .background(Palette.base)
        .tint(Palette.accent)
        .sheet(isPresented: $model.showCurveImport) {
            if let draft = model.curveDraft { CurveImportSheet(draft: draft).environmentObject(model) }
        }
        .sheet(isPresented: $showPlaylistExport) {
            PlaylistExportView(workspace: model.web).environmentObject(model)
        }
        .alert("需要处理", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: model.mode) { _, _ in model.recompute() }
        .onChange(of: model.selectedTrackID) { _, _ in model.recompute() }
        .onChange(of: model.selectedHeadphoneID) { _, _ in model.recompute() }
        .onChange(of: model.selectedPlaylistID) { _, _ in model.recompute() }
        .onChange(of: model.sort) { _, _ in model.recompute() }
        .onChange(of: model.includePartial) { _, _ in model.recompute() }
        .onChange(of: model.isFollowPlaying) { _, enabled in
            if enabled { model.syncFollowedPlayback() }
        }

    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                brandIcon
                VStack(alignment: .leading, spacing: 1) { Text("共鸣").font(.system(size: 22, weight: .semibold)); Text("RESONANCE").font(.system(size: 9, design: .monospaced)).tracking(2.5).foregroundStyle(Palette.muted) }
            }.padding(.bottom, 46)
            Text("聆听方式").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.bottom, 13)
            ForEach(WorkMode.allCases) { mode in
                Button {
                    model.mode = mode; model.showLibrary = false; model.showBrowser = false
                } label: {
                    HStack(spacing: 11) { Image(systemName: mode.icon).frame(width: 21); Text(mode.rawValue).font(.system(size: 13, weight: .medium)); Spacer() }
                        .foregroundStyle(model.mode == mode && !model.showLibrary && !model.showBrowser ? Palette.accent : Color.white.opacity(0.72))
                        .padding(.horizontal, 12).padding(.vertical, 13)
                        .background(model.mode == mode && !model.showLibrary && !model.showBrowser ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.vertical, 25)
            Button { model.showLibrary = true; model.showBrowser = false } label: { Label("我的声学资料库", systemImage: "square.stack.3d.up").font(.system(size: 12)).foregroundStyle(model.showLibrary ? Palette.accent : Palette.muted) }.buttonStyle(.plain)
            Button { model.openWebsite("https://huihifi.com/home") } label: { Label("查询耳机曲线", systemImage: "globe").font(.system(size: 12)).foregroundStyle(Palette.muted) }.buttonStyle(.plain).padding(.top, 19)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("自动积累听歌资料", isOn: Binding(
                    get: { model.automaticListeningEnabled },
                    set: { model.setAutomaticListeningEnabled($0) }
                )).toggleStyle(.switch).font(.system(size: 11))
                Text(model.automaticListeningEnabled ? model.automaticListeningStatus : "已关闭 · 下次启动保留此选择")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Text("连续录音 · 数据留在本机")
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
            }.padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("已拥有耳机"); Spacer(); Text("\(model.headphones.filter(\.owned).count)").monospacedDigit().foregroundStyle(.white) }
                HStack { Text("已分析录音"); Spacer(); Text("\(model.analyzedCount)").monospacedDigit().foregroundStyle(.white) }
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.vertical, 20)
            Text("频响 × 真实音频").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            Text("所有声学计算在本机完成").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 5)
        }.padding(.horizontal, 20).padding(.top, 42).padding(.bottom, 25).frame(width: 220).background(.black.opacity(0.14))
    }

    @ViewBuilder
    private var brandIcon: some View {
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 32, height: 32)
        } else if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
                  let icon = NSImage(contentsOfFile: iconPath) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: "waveform.path")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(Palette.accent)
        }
    }

    private var workspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.mode.rawValue).font(.system(size: 27, weight: .medium))
                        Text(model.mode.subtitle).font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button("导入音频", systemImage: "arrow.down.document") { model.chooseAudioFiles() }.disabled(model.busy)
                    Button("导入频响", systemImage: "waveform.path") { model.chooseCurveFile() }
                }.buttonStyle(.bordered).padding(.bottom, 4)
                if model.headphones.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("先算一首试试").font(.headline)
                            Text("加载拉斐尔曲线，再导入音频或录一段歌。参考可以随时更换。")
                                .font(.callout).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button("使用拉斐尔示例") { model.loadRaphaelSample() }.buttonStyle(.borderedProminent)
                    }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
                }
                PlaybackPanel()
                if model.mode == .song { songSelection } else { headphoneSelection }
                HStack(alignment: .top, spacing: 20) {
                    resultsPanel.frame(minWidth: 300, idealWidth: 360, maxWidth: 410)
                    detailPanel.frame(maxWidth: .infinity)
                }
            }.padding(30)
        }
    }

    private var songSelection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionCaption(title: "选择录音", trailing: "\(model.tracks.count) RECORDINGS")
                Toggle("跟随当前播放", isOn: $model.isFollowPlaying).toggleStyle(.checkbox).font(.caption)
            }
            if model.tracks.isEmpty {
                HStack { Text("导入本地音频，或采集网易云当前播放片段。 ").foregroundStyle(Palette.muted); Spacer() }.font(.callout)
            } else {
                Picker("歌曲", selection: Binding(get: { model.selectedTrackID }, set: { model.isFollowPlaying = false; model.selectedTrackID = $0 })) {
                    Text("请选择歌曲").tag(UUID?.none)
                    ForEach(model.tracks) { item in Text("\(item.title) · \(item.artist.isEmpty ? item.source : item.artist)\(item.analyzed ? "" : " · 待采集")").tag(Optional(item.id)) }
                }.labelsHidden()
                if let track = model.selectedTrack {
                    if model.isFollowPlaying, track.analyzed,
                       let currentID = model.player.snapshot?.trackID,
                       currentID == track.neteaseID, track.id != model.captureTrackID {
                        Text("显示已有录音分析 · \(track.importedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                    HStack(spacing: 8) {
                        TinyBadge(text: track.coverageLabel, color: track.isFull ? Palette.accent : .orange)
                        TinyBadge(text: track.sampleRate.map { "\(Int($0)) Hz" } ?? "待分析")
                        TinyBadge(text: "\(track.channels ?? 0) 声道")
                        TinyBadge(text: track.processingState)
                        Spacer()
                        Text(durationLabel(track.capturedSeconds)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                }
            }
        }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
    }

    private var headphoneSelection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 16) {
                Picker("耳机", selection: $model.selectedHeadphoneID) {
                    Text("选择耳机").tag(UUID?.none)
                    ForEach(model.headphones) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("范围", selection: $model.selectedPlaylistID) {
                    Text("全部本地录音").tag(UUID?.none)
                    ForEach(model.playlists) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("导入网易云歌单") { model.openWebsite("https://music.163.com/#/my/m/music/playlist") }
            }
            HStack {
                Picker("排序", selection: $model.sort) { ForEach(SongSort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 380)
                Spacer()
                Toggle("包含采集片段", isOn: $model.includePartial).toggleStyle(.checkbox).font(.system(size: 11))
                Button("生成网易云歌单…") { showPlaylistExport = true }
                    .disabled(model.results.filter(\.eligible).isEmpty && model.web.pendingPlaylistWrite == nil)
                Button("导出结果…") { model.exportCandidatePlaylist() }.disabled(model.results.filter(\.eligible).isEmpty)
            }
        }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(title: model.mode == .song ? "耳机与这首歌" : "候选歌曲", trailing: "\(model.results.count) RESULTS")
            if Set(model.results.filter(\.eligible).map(\.comparisonGroup)).count > 1 {
                Text("结果按参考和实际频段分组。").font(.caption).foregroundStyle(.orange)
            }
            if model.results.isEmpty {
                EmptyPanel(icon: model.mode.icon, title: model.mode == .song ? "从你的耳机开始" : "等待真实音频", detail: model.mode == .song ? "加载耳机曲线，选一个参考，再选一首音频。" : "选择耳机，再导入或采集你想比较的歌曲。")
            } else {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                    if result.eligible && (index == 0 || model.results[index - 1].comparisonGroup != result.comparisonGroup) {
                        Text(result.comparisonLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent).padding(.top, 10)
                    }
                    Button { model.selectedResultID = result.id } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { Text(result.name).font(.system(size: 13, weight: .medium)).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.muted) }
                            Text(result.subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2)
                            if result.eligible {
                                HStack { metric("D", result.d); metric("高频偏差", result.high); if model.mode == .headphone && model.sort == .character { metric("变化", result.c, digits: 3) } }
                            } else { Text(result.reason).font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9)).lineLimit(3) }
                        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selectedResult?.id == result.id ? Palette.accent.opacity(0.08) : Palette.panel, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.selectedResult?.id == result.id ? Palette.accent.opacity(0.28) : .clear))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func metric(_ label: String, _ value: Double?, digits: Int = 1) -> some View {
        HStack(spacing: 4) { Text(label).foregroundStyle(Palette.muted); Text(value.map { String(format: "%.*f", digits, $0) } ?? "—").foregroundStyle(.white) }.font(.system(size: 10, design: .monospaced)).padding(.trailing, 6)
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCaption(title: "这首歌的频段表现", trailing: "频响 × 歌曲能量")
            if !model.spectrumLine.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("歌曲平均功率谱 · dB/Hz（数字域）").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    FrequencyPlot(lines: [PlotLine(id: "audio", values: Array(zip(model.spectrumFrequencies, model.spectrumLine)), color: Palette.accent)], minDB: -120, maxDB: 0, maxFrequency: max(20_000, min(100_000, model.spectrumFrequencies.last ?? 50_000))).frame(height: 160)
                }
            }
            if let result = model.selectedResult {
                if let d = result.d {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(format: "%.1f dB", d)).font(.system(size: 32, weight: .medium, design: .rounded))
                        Text("参考偏差 D").font(.callout).foregroundStyle(Palette.muted)
                    }
                    Text("越小越接近所选参考；不是音质打分。").font(.caption).foregroundStyle(Palette.muted)
                }
                Text(result.reason).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if !result.bands.isEmpty { bandTable(result.bands) }
            } else {
                EmptyPanel(icon: "chart.xyaxis.line", title: "选一首歌，看看哪里突出", detail: "这里会显示歌曲的能量分布，以及耳机相对参考的变化。")
            }
        }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
    }

    private func bandTable(_ bands: [BandPresentation]) -> some View {
        VStack(spacing: 0) {
            HStack { Text("Hz").frame(width: 95, alignment: .leading); Text("能量").frame(width: 57, alignment: .trailing); Text("增益 dB").frame(width: 65, alignment: .trailing); Text("状态").frame(maxWidth: .infinity, alignment: .trailing) }.font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted).padding(.vertical, 8)
            ForEach(bands) { band in
                HStack(spacing: 6) {
                    Text(band.label).frame(width: 95, alignment: .leading)
                    Text(band.share.map { String(format: "%.2f%%", $0 * 100) } ?? "—").frame(width: 57, alignment: .trailing)
                    Text(band.gain.map { String(format: "%+.1f", $0) } ?? "—").frame(width: 65, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(band.status)
                        if band.status == "部分覆盖", let low = band.actualLow, let high = band.actualHigh { Text("实际 \(frequencyLabel(low))–\(frequencyLabel(high))") }
                    }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .trailing)
                }.font(.system(size: 9, design: .monospaced)).padding(.vertical, 6)
                    .foregroundStyle(band.low >= 20_000 ? Color.orange.opacity(0.8) : Color.white.opacity(0.8))
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.04)).frame(height: 1) }
            }
        }
    }
}

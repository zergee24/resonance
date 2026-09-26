import SwiftUI
import AppKit
import ResonanceCore

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
                    Text(model.status).font(.system(size: 18)).foregroundStyle(Palette.muted).lineLimit(2)
                    Spacer()
                    Text("LOCAL AUDIO").font(.system(size: 18, design: .monospaced)).foregroundStyle(Palette.muted.opacity(0.55))
                }.padding(.horizontal, 24).padding(.vertical, 12).frame(minHeight: 60)
            }
        }
        .font(Typography.body)
        .controlSize(.large)
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
        .onChange(of: model.sort) { _, _ in model.resortResults() }
        .onChange(of: model.includePartial) { _, _ in model.recompute() }
        .onChange(of: model.isFollowPlaying) { _, enabled in
            if enabled { model.syncFollowedPlayback() }
        }

    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                brandIcon
                VStack(alignment: .leading, spacing: 1) { Text("共鸣").font(.system(size: 22, weight: .semibold)); Text("RESONANCE").font(.system(size: 18, design: .monospaced)).tracking(2.5).foregroundStyle(Palette.muted) }
            }.padding(.bottom, 28)
            Text("聆听方式").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.muted).padding(.bottom, 13)
            ForEach(WorkMode.allCases) { mode in
                Button {
                    model.mode = mode; model.showLibrary = false; model.showBrowser = false
                } label: {
                    HStack(spacing: 11) { Image(systemName: mode.icon).frame(width: 21); Text(mode.rawValue).font(.system(size: 20, weight: .medium)); Spacer() }
                        .foregroundStyle(model.mode == mode && !model.showLibrary && !model.showBrowser ? Palette.accent : Color.white.opacity(0.72))
                        .padding(.horizontal, 12).padding(.vertical, 13)
                        .background(model.mode == mode && !model.showLibrary && !model.showBrowser ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.vertical, 20)
            Button { model.showLibrary = true; model.showBrowser = false } label: { Label("我的声学资料库", systemImage: "square.stack.3d.up").font(.system(size: 18)).foregroundStyle(model.showLibrary ? Palette.accent : Palette.muted) }.buttonStyle(.plain)
            Button { model.openWebsite("https://huihifi.com/home") } label: { Label("查询耳机曲线", systemImage: "globe").font(.system(size: 18)).foregroundStyle(Palette.muted) }.buttonStyle(.plain).padding(.top, 19)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("自动积累听歌资料", isOn: Binding(
                    get: { model.automaticListeningEnabled },
                    set: { model.setAutomaticListeningEnabled($0) }
                )).toggleStyle(.switch).font(.system(size: 18))
                Text(model.automaticListeningEnabled ? model.automaticListeningStatus : "已关闭 · 下次启动保留此选择")
                    .font(.system(size: 18)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Text("连续录音 · 数据留在本机")
                    .font(.system(size: 18)).foregroundStyle(Palette.muted)
            }.padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("已拥有耳机"); Spacer(); Text("\(model.headphones.filter(\.owned).count)").monospacedDigit().foregroundStyle(.white) }
                HStack { Text("已分析录音"); Spacer(); Text("\(model.analyzedCount)").monospacedDigit().foregroundStyle(.white) }
            }.font(.system(size: 18)).foregroundStyle(Palette.muted)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.vertical, 20)
            Text("频响 × 真实音频").font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            Text("所有声学计算在本机完成").font(.system(size: 18)).foregroundStyle(Palette.muted).padding(.top, 5)
        }.padding(.horizontal, 22).padding(.top, 36).padding(.bottom, 24).frame(width: 286).background(.black.opacity(0.14))
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
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Palette.accent)
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.mode.rawValue).font(.system(size: 32, weight: .medium))
                        Text(model.mode.subtitle).font(.system(size: 20)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button("导入音频", systemImage: "arrow.down.document") { model.chooseAudioFiles() }.disabled(model.busy)
                    Button("导入频响", systemImage: "waveform.path") { model.chooseCurveFile() }
                }.buttonStyle(.bordered).padding(.bottom, 4)
                if model.headphones.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("先算一首试试").font(Typography.heading)
                            Text("加载拉斐尔曲线，再导入音频或录一段歌。参考可以随时更换。")
                                .font(Typography.body).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button("使用拉斐尔示例") { model.loadRaphaelSample() }.buttonStyle(.borderedProminent)
                    }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
                }
                PlaybackPanel()
                if model.mode == .song { songSelection } else { headphoneSelection }
                if geometry.size.width >= 1120 {
                    HStack(alignment: .top, spacing: 24) {
                        resultsPanel.frame(width: 440)
                        detailPanel.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.results.count > 3 {
                            ScrollView { resultsPanel }.frame(height: 420)
                        } else {
                            resultsPanel
                        }
                        detailPanel
                    }
                }
            }.padding(28)
        }
        }
    }

    private var songSelection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionCaption(title: "选择录音", trailing: "\(model.tracks.count) RECORDINGS")
                Toggle("跟随当前播放", isOn: $model.isFollowPlaying).toggleStyle(.checkbox).font(Typography.secondary)
            }
            if model.tracks.isEmpty {
                HStack { Text("导入本地音频，或采集网易云当前播放片段。 ").foregroundStyle(Palette.muted); Spacer() }.font(Typography.body)
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
                            .font(Typography.secondary).foregroundStyle(Palette.muted)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                        TinyBadge(text: track.coverageLabel, color: track.isFull ? Palette.accent : .orange)
                        TinyBadge(text: track.sampleRate.map { "\(Int($0)) Hz" } ?? "待分析")
                        TinyBadge(text: "\(track.channels ?? 0) 声道")
                        }
                        HStack(spacing: 8) {
                        TinyBadge(text: track.processingState)
                        Spacer()
                        Text(durationLabel(track.capturedSeconds)).font(.system(size: 18, design: .monospaced)).foregroundStyle(Palette.muted)
                        }
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
            if model.preferredReferences.isEmpty {
                Text("尚未选择个人偏好参考；可在声学资料库勾选“我喜欢的声音”。")
                    .font(Typography.secondary).foregroundStyle(Palette.muted)
            } else {
                Text("个人参考：\(model.preferredReferences.map { $0.name }.joined(separator: "、")) · 偏好接近度按整体 dB，低值更接近。")
                    .font(Typography.secondary).foregroundStyle(Palette.muted)
            }
            HStack {
                HStack(spacing: 6) {
                    Text("排序").font(.system(size: 18)).foregroundStyle(Palette.muted)
                    Picker("排序", selection: $model.sort) {
                        ForEach(SongSort.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().frame(minWidth: 128, alignment: .leading)
                }
                Spacer()
                Toggle("包含采集片段", isOn: $model.includePartial).toggleStyle(.checkbox).font(.system(size: 18))
                Button("生成网易云歌单…") { showPlaylistExport = true }
                    .disabled(model.results.filter(\.eligible).isEmpty && model.web.pendingPlaylistWrite == nil)
                Button("导出结果…") { model.exportCandidatePlaylist() }.disabled(model.results.filter(\.eligible).isEmpty)
            }
        }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(title: model.mode == .song ? "耳机与这首歌" : "候选歌曲", trailing: "\(model.results.count) RESULTS")
            if model.mode == .headphone && model.sort == .character {
                Text("C 只表示谱形变化更明显，不代表更好听；偏好接近度请看低 dB。")
                    .font(Typography.secondary).foregroundStyle(Palette.muted)
            }
            if Set(model.results.filter(\.eligible).map(\.comparisonGroup)).count > 1 {
                Text("结果按参考和实际频段分组。").font(Typography.secondary).foregroundStyle(.orange)
            }
            if model.results.isEmpty {
                EmptyPanel(icon: model.mode.icon, title: model.mode == .song ? "从你的耳机开始" : "等待真实音频", detail: model.mode == .song ? "加载耳机曲线，选一个参考，再选一首音频。" : "选择耳机，再导入或采集你想比较的歌曲。")
            } else {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                    if result.eligible && (index == 0 || model.results[index - 1].comparisonGroup != result.comparisonGroup) {
                        Text(result.comparisonLabel).font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.accent).padding(.top, 10)
                    }
                    Button { model.selectedResultID = result.id } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { Text(result.name).font(.system(size: 20, weight: .medium)).lineLimit(2); Spacer(); Image(systemName: "chevron.right").font(.system(size: 18)).foregroundStyle(Palette.muted) }
                            Text(result.subtitle).font(.system(size: 18)).foregroundStyle(Palette.muted).lineLimit(2)
                            if let personal = result.personalMatch {
                                personalSummary(personal, bestReferenceName: result.bestReferenceName)
                            }
                            if result.eligible {
                                HStack { metric("D", result.d); metric("高频偏差", result.high); if model.mode == .headphone && model.sort == .character { metric("C 谱形变化", result.c, digits: 3) } }
                            } else { Text(result.reason).font(.system(size: 18)).foregroundStyle(.orange.opacity(0.9)).lineLimit(3) }
                        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selectedResult?.id == result.id ? Palette.accent.opacity(0.08) : Palette.panel, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.selectedResult?.id == result.id ? Palette.accent.opacity(0.28) : .clear))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func metric(_ label: String, _ value: Double?, digits: Int = 1) -> some View {
        HStack(spacing: 4) { Text(label).foregroundStyle(Palette.muted); Text(value.map { String(format: "%.*f", digits, $0) } ?? "—").foregroundStyle(.white) }.font(.system(size: 18, design: .monospaced)).padding(.trailing, 6)
    }

    private func personalSummary(_ personal: PersonalMatchResult, bestReferenceName: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("偏好接近度").foregroundStyle(Palette.muted)
                Text("低 dB 更接近").foregroundStyle(Palette.muted.opacity(0.8))
            }
            if let name = bestReferenceName ?? personal.matches.first(where: { $0.referenceID == personal.bestReferenceID })?.referenceName {
                Text("最佳：\(name)").foregroundStyle(Palette.accent).lineLimit(2)
            }
            ForEach(personal.matches.prefix(2)) { match in
                HStack(spacing: 5) {
                    Text(match.referenceName).lineLimit(2)
                    Spacer()
                    Text(match.overallDeviationDB.map { String(format: "%.1f dB", $0) } ?? "—")
                        .font(.system(size: 18, design: .monospaced)).foregroundStyle(.white)
                }
            }
        }.font(.system(size: 18))
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCaption(title: "这首歌的频段表现", trailing: "频响 × 歌曲能量")
            if !model.spectrumLine.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("歌曲平均功率谱 · dB/Hz（数字域）").font(.system(size: 18)).foregroundStyle(Palette.muted)
                    FrequencyPlot(lines: [PlotLine(id: "audio", values: Array(zip(model.spectrumFrequencies, model.spectrumLine)), color: Palette.accent)], minDB: -120, maxDB: 0, maxFrequency: max(20_000, min(100_000, model.spectrumFrequencies.last ?? 50_000))).frame(height: 240)
                }
            }
            if let result = model.selectedResult {
                if let personal = result.personalMatch {
                    personalDetail(personal, bestReferenceID: result.bestReferenceID)
                }
                if let d = result.d {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(format: "%.1f dB", d)).font(.system(size: 32, weight: .medium, design: .rounded))
                        Text("参考偏差 D").font(Typography.body).foregroundStyle(Palette.muted)
                    }
                    Text("越小越接近所选参考；不是音质打分。").font(Typography.secondary).foregroundStyle(Palette.muted)
                }
                Text(result.reason).font(.system(size: 18)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if !result.bands.isEmpty { bandTable(result.bands) }
            } else {
                EmptyPanel(icon: "chart.xyaxis.line", title: "选一首歌，看看哪里突出", detail: "这里会显示歌曲的能量分布，以及耳机相对参考的变化。")
            }
        }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
    }

    private func personalDetail(_ personal: PersonalMatchResult, bestReferenceID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("偏好参考 · \(personal.matches.count) 条独立结果").font(.system(size: 18, weight: .semibold))
                Spacer()
                if let low = personal.commonMinimumHz, let high = personal.commonMaximumHz {
                    Text("共同 \(frequencyLabel(low))–\(frequencyLabel(high)) Hz")
                        .font(.system(size: 18, design: .monospaced)).foregroundStyle(Palette.muted)
                }
            }
            Text("低 dB 表示更接近该参考；P90 按压缩帧能量加权。最大差异位置是录音内时间，不等于最易听见的差异。")
                .font(Typography.secondary).foregroundStyle(Palette.muted)
            ForEach(personal.matches) { match in
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(match.referenceName).font(.system(size: 18, weight: .medium))
                        HStack {
                        if match.referenceID == bestReferenceID { TinyBadge(text: "最佳参考", color: Palette.accent) }
                        Spacer()
                        Text(personalStatusLabel(match.status)).font(Typography.secondary).foregroundStyle(match.status == .evaluated ? Palette.accent : .orange)
                        }
                    }
                    HStack(spacing: 12) {
                        personalMetric("整体", match.overallDeviationDB)
                        personalMetric("10–20k", match.highFrequencyDeviationDB)
                        personalMetric("P90", match.frameErrorP90DB)
                    }
                    if let time = match.worstFrameStartTimeSeconds {
                        Text("录音内差异最大位置约 \(durationLabel(time))\(match.worstFrameErrorDB.map { " · \(String(format: "%.1f dB", $0))" } ?? "")")
                            .font(Typography.secondary).foregroundStyle(Palette.muted)
                    }
                    if let upper = match.evaluatedMaxHz, upper < 20_000 {
                        Text("10–20 kHz 实际上限 \(frequencyLabel(upper)) Hz；未向上外推")
                            .font(Typography.secondary).foregroundStyle(.orange.opacity(0.85))
                    }
                    let extended = match.frequencyEvidence.filter(\.isExtendedFrequency)
                    if !extended.isEmpty {
                        Text("扩展频段：\(extended.map { "\(frequencyLabel($0.lowerHz))–\(frequencyLabel($0.upperHz)) Hz" }.joined(separator: "、"))")
                            .font(Typography.secondary).foregroundStyle(.orange.opacity(0.8))
                    }
                    if !match.limitations.isEmpty {
                        Text(match.limitations.joined(separator: "；")).font(Typography.secondary).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                }.padding(10).background(Palette.base.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func personalMetric(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Palette.muted)
            Text(value.map { String(format: "%.1f dB", $0) } ?? "—")
                .font(.system(size: 18, design: .monospaced)).foregroundStyle(.white)
        }.font(.system(size: 18))
    }

    private func personalStatusLabel(_ status: PersonalReferenceMatch.Status) -> String {
        switch status {
        case .evaluated: return "已计算"
        case .partial: return "部分覆盖"
        case .noAudioContent: return "无歌曲能量"
        case .unavailable: return "不可用"
        }
    }

    private func bandTable(_ bands: [BandPresentation]) -> some View {
        VStack(spacing: 0) {
            HStack { Text("Hz").frame(width: 130, alignment: .leading); Text("能量").frame(width: 96, alignment: .trailing); Text("增益 dB").frame(width: 94, alignment: .trailing); Text("状态").frame(maxWidth: .infinity, alignment: .trailing) }.font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.muted).padding(.vertical, 8)
            ForEach(bands) { band in
                HStack(spacing: 6) {
                    Text(band.label).frame(width: 130, alignment: .leading)
                    Text(band.share.map { String(format: "%.2f%%", $0 * 100) } ?? "—").frame(width: 96, alignment: .trailing)
                    Text(band.gain.map { String(format: "%+.1f", $0) } ?? "—").frame(width: 94, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(band.status)
                        if band.status == "部分覆盖", let low = band.actualLow, let high = band.actualHigh { Text("实际 \(frequencyLabel(low))–\(frequencyLabel(high))") }
                    }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .trailing)
                }.font(.system(size: 18, design: .monospaced)).padding(.vertical, 6)
                    .foregroundStyle(band.low >= 20_000 ? Color.orange.opacity(0.8) : Color.white.opacity(0.8))
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.04)).frame(height: 1) }
            }
        }
    }
}

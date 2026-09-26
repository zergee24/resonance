import AppKit
import SwiftUI
import ResonanceCore

struct PlaybackPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View { PlaybackContents(player: model.player, capture: model.capture).environmentObject(model) }
}

struct PlaybackContents: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerObserver
    @ObservedObject var capture: AudioCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Palette.accent.opacity(0.10)).frame(width: 44, height: 44)
                    Image(systemName: capture.isRecording ? "waveform" : "play.rectangle").foregroundStyle(Palette.accent)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.snapshot?.title ?? "当前系统播放").font(.system(size: 13, weight: .medium))
                    Text(player.snapshot?.artist ?? player.status.message).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    if let snapshot = player.snapshot {
                        HStack(spacing: 5) {
                            Text("来源：\(sourceLabel(for: snapshot)) · \(snapshot.metadataSource.label)")
                            if let bundleID = snapshot.sourceBundleIdentifier, !bundleID.isEmpty {
                                Text(bundleID).lineLimit(1).truncationMode(.middle)
                            }
                            if let processID = snapshot.sourceProcessIdentifier {
                                Text("PID \(processID)")
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        if let currentTime = snapshot.currentTime, let duration = snapshot.duration, duration > 0 {
                            HStack(spacing: 7) {
                                ProgressView(value: min(max(currentTime / duration, 0), 1))
                                Text("\(durationLabel(currentTime)) / \(durationLabel(duration))")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(Palette.muted)
                        }
                    }
                }
                Spacer()
                if capture.isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationLabel(context.date.timeIntervalSince(model.captureStartedAt ?? context.date))).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.accent)
                    }
                    ProgressView(value: Double(min(1, capture.meter))).frame(width: 70)
                    Button("停止并分析", systemImage: "stop.fill") {
                        model.automaticListeningPolicy.markCaptureAttempted()
                        model.finishCapture()
                    }.buttonStyle(.borderedProminent)
                        .help("停止当前连续段；自动积累保持开启，下一次切歌或暂停后恢复播放时继续。")
                } else {
                    Button("读取当前歌曲") { player.start(); player.refresh() }
                    Button("采集网易云音频", systemImage: "record.circle") { model.beginCapture() }
                        .disabled(model.busy || capture.status == .starting || hasExplicitOtherSource)
                        .help(hasExplicitOtherSource ? "当前系统播放来源不是网易云" : "采集网易云当前播放音频")
                }
            }
            HStack(spacing: 12) {
                if player.permissionNeeded { Button("允许辅助功能") { _ = player.requestAccessibilityPermission() } }
                if !player.screenCaptureFallbackEnabled { Button("启用窗口识别备选") { _ = player.enableScreenCaptureFallback() } }
                else { Button("关闭窗口识别") { player.disableScreenCaptureFallback() } }
                if player.snapshot?.isCandidate == true { TinyBadge(text: "未关联网易云 ID", color: .orange) }
                if hasExplicitOtherSource { TinyBadge(text: "当前来源不采集", color: .orange) }
                Spacer()
                Text(capture.isRecording ? "只采集网易云进程 · 本地保存" : (hasExplicitOtherSource ? "仅显示系统播放信息" : "音频采集与歌曲识别可分别使用"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.font(.system(size: 10)).buttonStyle(.link)
            if let issue = player.systemPlayerIssue,
               player.snapshot?.metadataSource != .systemPlayer {
                Text("系统播放器读取失败：\(issue)；可使用辅助功能或窗口识别")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            if case .failed(let message) = capture.status {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    if model.automaticListeningEnabled {
                        Button("重试当前歌曲采集") { model.retryAutomaticCapture() }
                    }
                }
            }
            if !capture.isRecording {
                Toggle("播放处理与候选一致（仅作备注）", isOn: $model.sharedProcessingDeclared)
                    .toggleStyle(.checkbox).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
            .onAppear { model.installPlayerEvents() }
    }

    private var hasExplicitOtherSource: Bool {
        guard let snapshot = player.snapshot,
              let bundleID = snapshot.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return false }
        return !player.canCaptureCurrentSource
    }

    private func sourceLabel(for snapshot: PlayerSnapshot) -> String {
        if let application = snapshot.sourceApplicationName?.trimmingCharacters(in: .whitespacesAndNewlines), !application.isEmpty {
            return application
        }
        return "当前来源"
    }
}

extension AppModel {
    func beginCapture(automatically: Bool = false, trackID: UUID? = nil) {
        guard (automatically || !busy), !capture.isRecording, captureStartTask == nil, !isShuttingDown, let database else { return }
        if automatically && !player.canCaptureCurrentSource {
            automaticListeningStatus = "当前来源不是网易云，等待网易云播放"
            return
        }
        if !automatically,
           let snapshot = player.snapshot,
           let bundleID = snapshot.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleID.isEmpty,
           !player.canCaptureCurrentSource {
            errorMessage = "当前系统播放来源不是网易云，请先切换到网易云音乐。"
            return
        }
        guard let processID = player.processIdentifier else {
            if automatically { automaticListeningStatus = "网易云进程已退出，等待播放器重新打开" }
            else { errorMessage = "请先打开网易云音乐并播放要分析的歌曲。" }
            return
        }
        let requestID = UUID()
        captureRequestID = requestID
        captureIsAutomatic = automatically
        captureTrackID = trackID
        captureIdentity = player.snapshot
        status = "正在连接网易云进程音频…"
        if automatically { automaticListeningStatus = "正在启动连续采集" }
        else { automaticListeningPolicy.markCaptureAttempted() }
        captureStartTask = Task {
            defer { captureStartTask = nil }
            do {
                capturedProcessingDeclaration = sharedProcessingDeclared
                capturedProcessID = processID
                lastPlayerPosition = nil
                let beforeStart = captureIdentity
                let url = database.directory.appendingPathComponent("Audio/capture-\(UUID().uuidString).caf")
                try await capture.start(pid: processID, destination: url)
                captureStartedAt = Date()
                guard captureRequestID == requestID, !isShuttingDown,
                      !automatically || automaticListeningEnabled else {
                    finishCapture(boundaryNote: "采集启动已取消，按已录内容估计。")
                    return
                }
                captureRequestID = nil
                let afterStart = player.snapshot
                if let beforeStart, let afterStart, beforeStart.candidateKey != afterStart.candidateKey {
                    finishCapture(boundaryNote: "采集启动期间曲目变化，按已录内容估计。")
                    return
                }
                if let afterStart,
                   afterStart.sourceBundleIdentifier != nil,
                   !player.canCaptureCurrentSource {
                    finishCapture(boundaryNote: "采集启动期间检测到当前来源不是网易云，按已录内容估计。")
                    return
                }
                if automatically && player.snapshot?.playbackState != .playing {
                    finishCapture(boundaryNote: "采集启动期间播放停止，按已录内容估计。")
                    return
                }
                captureIdentity = afterStart ?? beforeStart
                status = "正在连续采集实际播放内容；覆盖不足的录音会保留为片段。"
            } catch {
                captureRequestID = nil
                if case AudioCaptureError.startCancelled = error {
                    status = "采集启动已取消"
                } else if automatically {
                    automaticListeningStatus = "采集失败：\(error.localizedDescription)"
                    if let trackID, var track = tracks.first(where: { $0.id == trackID }) {
                        track.error = "已记录歌曲信息，音频采集未成功：\(error.localizedDescription)"
                        do { try saveTrack(track) } catch { automaticListeningStatus = error.localizedDescription }
                    }
                } else { report(error) }
            }
        }
    }

    func finishCapture(boundaryNote: String? = nil, summaryOverride: CaptureSummary? = nil) {
        guard let summary = summaryOverride ?? capture.stop(), let database else { return }
        let wallClockStart = captureStartedAt
        captureStartedAt = nil
        let identity = captureIdentity
        let processingDeclared = capturedProcessingDeclaration
        let automatic = captureIsAutomatic
        let storedID = captureTrackID
        let processID = capturedProcessID
        captureIdentity = nil
        captureTrackID = nil
        captureIsAutomatic = false
        let stoppedAt = Date()
        var notes = ["已录 \(String(format: "%.1f", summary.duration)) 秒；完整度未知，按片段估计。"]
        if let boundaryNote { notes.append(boundaryNote) }
        if identity?.trackID == nil {
            notes.append(identity?.metadataSource == .systemPlayer ? "歌曲信息来自系统播放器，尚未关联网易云 ID。" : "歌曲身份仅为候选，按已录内容估计。")
        }
        if processingDeclared {
            notes.append("用户备注：播放处理与候选一致。")
        } else {
            notes.append("播放处理未知，按已录内容估计。")
        }
        if summary.droppedFrames > 0 {
            notes.append("采集有 \(summary.droppedFrames) 帧丢失，按已录内容估计。")
        }
        if summary.duration < 15 {
            notes.append("样本较短，按已录内容估计。")
        }
        if let mediaStart = identity?.currentTime {
            notes.append("播放器报告位置约 \(String(format: "%.1f", mediaStart)) 秒，仅作备注。")
        }
        var track = TrackEntry(title: identity?.title ?? "未识别片段 \(stoppedAt.formatted(date: .omitted, time: .shortened))", artist: identity?.artist ?? "", neteaseID: identity?.trackID, sourceURL: identity?.trackURL?.absoluteString, audioPath: summary.destination.path, duration: identity?.duration, capturedSeconds: summary.duration, sampleRate: summary.sampleRate, channels: summary.channelCount, isFull: false, processingState: "音频已保存，等待分析", source: automatic ? "自动听歌采集" : "网易云进程采集")
        if let storedID { track.id = storedID }
        track.analysisNotes = notes
        track.mediaStartSeconds = identity?.currentTime
        track.wallClockStartedAt = wallClockStart
        track.droppedFrames = summary.droppedFrames
        track.sourceProcessID = processID
        track.sourceBundleIdentifier = identity?.sourceBundleIdentifier
        track.sourceApplicationName = identity?.sourceApplicationName
        track.metadataSource = identity?.metadataSource.rawValue
        // Persist before analysis so quitting or a numerical failure cannot
        // erase the history entry or leave an unreferenced successful capture.
        do { try saveTrack(track) } catch { report(error); return }
        let previousAnalysis = analysisTask
        let revision = UUID()
        analysisRevision = revision
        busy = true
        analysisTask = Task {
            await previousAnalysis?.value
            busy = true
            defer { if analysisRevision == revision { busy = false } }
            do {
                if let error = summary.writerError { throw ListeningCaptureError.invalid(error) }
                guard summary.formatMismatchFrames == 0 else { throw ListeningCaptureError.invalid("采集格式中途变化，此段未用于匹配。") }
                guard summary.hasAudioData else { throw ListeningCaptureError.invalid("没有采到有效音频。请确认网易云正在播放，且已允许共鸣录制系统音频。") }
                let audioDuration = summary.duration
                status = "正在分析已录片段 · \(track.title)"
                let coverage = try Coverage(
                    kind: .partial,
                    mediaDurationSeconds: identity?.duration,
                    recordedDurationSeconds: audioDuration,
                    intervals: [],
                    hasUnexplainedGaps: summary.droppedFrames > 0,
                    identityConfirmed: identity?.trackID != nil
                )
                let id = track.id, destination = summary.destination
                let analyzed = try await Task.detached(priority: .userInitiated) { (try SpectrumAnalyzer().analyze(fileURL: destination, coverage: coverage, recordingID: id), try LocalStore.audioDigest(destination)) }.value
                track.contentSHA256 = analyzed.1
                let artifactURL = database.featureURL(id: id)
                try await Task.detached(priority: .utility) { try LocalStore.writeArtifact(analyzed.0, to: artifactURL) }.value
                track.featurePath = artifactURL.path
                track.processingState = processingDeclared ? "用户备注：播放处理与候选一致" : "播放器输出；处理链未知"
                try saveTrack(track)
                if !automatic || (isFollowPlaying && player.snapshot?.candidateKey == identity?.candidateKey) {
                    selectedTrackID = track.id
                }
                status = "已分析全部有效采集段 · \(String(format: "%.1f", audioDuration)) 秒 · \(track.coverageLabel)"
                if automatic { automaticListeningStatus = "已保存：\(track.title) · \(track.coverageLabel)" }
                recompute()
            } catch {
                track.error = error.localizedDescription
                do {
                    try saveTrack(track)
                    if automatic { automaticListeningStatus = "音频已保留：\(error.localizedDescription)" }
                    else { report(error) }
                } catch { report(error) }
            }
        }
    }
}

private enum ListeningCaptureError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

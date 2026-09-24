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
                    Text(player.snapshot?.title ?? "网易云 · 当前播放").font(.system(size: 13, weight: .medium))
                    Text(player.snapshot?.artist ?? player.status.message).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
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
                    Button("采集网易云音频", systemImage: "record.circle") { model.beginCapture() }.disabled(model.busy || capture.status == .starting)
                }
            }
            HStack(spacing: 12) {
                if player.permissionNeeded { Button("允许辅助功能") { _ = player.requestAccessibilityPermission() } }
                if !player.screenCaptureFallbackEnabled { Button("启用窗口识别备选") { _ = player.enableScreenCaptureFallback() } }
                else { Button("关闭窗口识别") { player.disableScreenCaptureFallback() } }
                if player.snapshot?.isCandidate == true { TinyBadge(text: "候选身份 · 未取得精确歌曲 ID", color: .orange) }
                Spacer()
                Text(capture.isRecording ? "只采集网易云进程 · 本地保存" : "音频采集与歌曲识别可分别使用").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.font(.system(size: 10)).buttonStyle(.link)
            if case .failed(let message) = capture.status {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    if model.automaticListeningEnabled {
                        Button("重试当前歌曲采集") { model.retryAutomaticCapture() }
                    }
                }
            }
            if !capture.isRecording {
                Toggle("比较这些耳机时，播放器使用相同设置，且没有耳机专属 EQ / 空间处理", isOn: $model.sharedProcessingDeclared)
                    .toggleStyle(.checkbox).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
            .onAppear { model.installPlayerEvents() }
    }
}

extension AppModel {
    func beginCapture(automatically: Bool = false, trackID: UUID? = nil) {
        guard (automatically || !busy), !capture.isRecording, captureStartTask == nil, !isShuttingDown, let database else { return }
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
        lastConfirmedCaptureSnapshot = nil
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
                    finishCapture(invalidReason: "采集启动已取消；原始片段不参与匹配。")
                    return
                }
                captureRequestID = nil
                captureIdentity = player.snapshot
                lastConfirmedCaptureSnapshot = captureIdentity
                if let beforeStart, let afterStart = player.snapshot, beforeStart.candidateKey != afterStart.candidateKey {
                    finishCapture(invalidReason: "采集启动期间曲目发生变化，片段归属不明，未参与推荐。")
                    return
                }
                if automatically && player.snapshot?.playbackState != .playing {
                    finishCapture(invalidReason: "采集启动期间播放已停止，片段未参与推荐。")
                    return
                }
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

    func finishCapture(invalidReason: String? = nil, excludingUncertainTail boundaryReason: String? = nil, summaryOverride: CaptureSummary? = nil) {
        guard let summary = summaryOverride ?? capture.stop(), let database else { return }
        let wallClockStart = captureStartedAt
        captureStartedAt = nil
        let identity = captureIdentity
        let sharedProcessing = capturedProcessingDeclaration
        let endIdentity = player.snapshot
        let lastConfirmed = lastConfirmedCaptureSnapshot
        let automatic = captureIsAutomatic
        let storedID = captureTrackID
        let processID = capturedProcessID
        captureIdentity = nil
        captureTrackID = nil
        captureIsAutomatic = false
        lastConfirmedCaptureSnapshot = nil
        let stoppedAt = Date()
        // A UI change arrives after the audio boundary. Keep the original PCM,
        // but exclude the tail since the last same-song observation plus two
        // polling periods. UI timing cannot prove a crossfade boundary: the
        // retained segment stays excluded from automatic ranking.
        let safeEnd: TimeInterval? = boundaryReason == nil ? nil : {
            guard let wallClockStart, let lastConfirmed,
                  lastConfirmed.candidateKey == identity?.candidateKey else { return 0 }
            return max(0, min(summary.duration, lastConfirmed.observedAt.timeIntervalSince(wallClockStart) - 1.2))
        }()
        var track = TrackEntry(title: identity?.title ?? "未识别片段 \(stoppedAt.formatted(date: .omitted, time: .shortened))", artist: identity?.artist ?? "", neteaseID: identity?.trackID, sourceURL: identity?.trackURL?.absoluteString, audioPath: summary.destination.path, duration: identity?.duration, capturedSeconds: summary.duration, sampleRate: summary.sampleRate, channels: summary.channelCount, isFull: false, processingState: "播放器输出；EQ / 响度处理未核实", source: automatic ? "自动听歌采集" : "网易云进程采集")
        if let storedID { track.id = storedID }
        track.comparisonAllowed = sharedProcessing && summary.droppedFrames == 0 && boundaryReason == nil
            && (!automatic || identity?.trackID != nil)
        track.mediaStartSeconds = identity?.currentTime
        track.wallClockStartedAt = wallClockStart
        track.droppedFrames = summary.droppedFrames
        track.sourceProcessID = processID
        if sharedProcessing { track.processingState = "用户声明：所有候选共用相同播放处理；未作信号验证" }
        // Persist before analysis so quitting or a numerical failure cannot
        // erase the history entry or leave an unreferenced successful capture.
        track.error = "音频已保存，等待分析"
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
                if let invalidReason { throw ListeningCaptureError.invalid(invalidReason) }
                if let error = summary.writerError { throw ListeningCaptureError.invalid(error) }
                guard summary.formatMismatchFrames == 0 else { throw ListeningCaptureError.invalid("采集格式中途变化，此段未用于匹配。") }
                guard summary.hasAudioData else { throw ListeningCaptureError.invalid("没有采到有效音频。请确认网易云正在播放，且已允许共鸣录制系统音频。") }
                var audioURL = summary.destination
                var audioDuration = summary.duration
                var nonzeroSeconds = Double(max(0, summary.capturedFrames - Int64(summary.zeroDataFrames))) / max(1, summary.sampleRate)
                if let safeEnd {
                    guard safeEnd > 0 else { throw ListeningCaptureError.invalid("歌曲边界无法确认，原始片段已保留，不参与匹配。") }
                    let trimmedURL = database.directory.appendingPathComponent("Audio/continuous-\(UUID().uuidString).caf")
                    let result = try await Task.detached(priority: .utility) {
                        try CapturedAudioWindow.trim(fileURL: summary.destination, to: trimmedURL, endSeconds: safeEnd)
                    }.value
                    audioURL = trimmedURL
                    audioDuration = result.durationSeconds
                    nonzeroSeconds = Double(result.nonzeroFrames) / result.sampleRate
                    track.rawAudioPath = summary.destination.path
                    track.audioPath = trimmedURL.path
                    track.capturedSeconds = audioDuration
                }
                guard nonzeroSeconds >= 15 else { throw ListeningCaptureError.invalid("非零音频不足 15 秒。原始采样已保留，此段未参与匹配。") }
                status = "正在分析完整采集段 · \(track.title)"
                var isComplete = false
                if boundaryReason == nil, let original = identity, let end = endIdentity,
                   let exactID = original.trackID, end.trackID == exactID,
                   let startPosition = original.currentTime, let endPosition = end.currentTime,
                   let duration = original.duration, duration > 0,
                   let started = wallClockStart {
                    isComplete = startPosition <= 0.25 && endPosition >= duration - 0.25
                        && abs(audioDuration - duration) <= 0.5
                        && abs(started.timeIntervalSince(original.observedAt)) <= 0.25
                        && abs(stoppedAt.timeIntervalSince(end.observedAt)) <= 0.25
                        && summary.droppedFrames == 0
                }
                track.isFull = isComplete
                let intervals: [TimeRange]
                if let mediaStart = identity?.currentTime {
                    intervals = [try TimeRange(startSeconds: mediaStart, endSeconds: mediaStart + audioDuration)]
                } else { intervals = [] }
                let coverage = try Coverage(kind: isComplete ? .complete : .partial, mediaDurationSeconds: identity?.duration, recordedDurationSeconds: audioDuration, intervals: intervals, hasUnexplainedGaps: summary.droppedFrames > 0, identityConfirmed: identity?.trackID != nil)
                let id = track.id, destination = audioURL
                let analyzed = try await Task.detached(priority: .userInitiated) { (try SpectrumAnalyzer().analyze(fileURL: destination, coverage: coverage, recordingID: id), try LocalStore.audioDigest(destination)) }.value
                track.contentSHA256 = analyzed.1
                let artifactURL = database.featureURL(id: id)
                try await Task.detached(priority: .utility) { try LocalStore.writeArtifact(analyzed.0, to: artifactURL) }.value
                track.featurePath = artifactURL.path
                track.error = boundaryReason.map { $0 + " 界面时间不能证明精确音频边界，此段仅存档，不参与自动排名。" }
                if summary.droppedFrames > 0 { track.error = "采集丢帧 \(summary.droppedFrames)，时间覆盖不连续" }
                if automatic && identity?.trackID == nil {
                    track.error = [track.error, "自动识别仅取得候选身份；已保留频谱，不参与自动排名。"].compactMap { $0 }.joined(separator: " ")
                }
                try saveTrack(track)
                if !automatic || (isFollowPlaying && player.snapshot?.candidateKey == identity?.candidateKey) {
                    selectedTrackID = track.id
                }
                status = "已分析全部有效采集段 · \(String(format: "%.1f", audioDuration)) 秒 · \(track.coverageLabel)"
                if automatic { automaticListeningStatus = "已保存：\(track.title) · \(track.coverageLabel)" }
                recompute()
            } catch {
                track.error = error.localizedDescription
                track.comparisonAllowed = false
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

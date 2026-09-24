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
                    Button("停止并分析", systemImage: "stop.fill") { model.finishCapture() }.buttonStyle(.borderedProminent)
                } else {
                    Button("读取当前歌曲") { player.start(); player.refresh() }
                    Button("采集网易云音频", systemImage: "record.circle") { model.beginCapture() }.disabled(model.busy)
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
            if case .failed(let message) = capture.status { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !capture.isRecording {
                Toggle("比较这些耳机时，播放器使用相同设置，且没有耳机专属 EQ / 空间处理", isOn: $model.sharedProcessingDeclared)
                    .toggleStyle(.checkbox).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
            .onAppear { model.installPlayerEvents() }
    }
}

extension AppModel {
    func installPlayerEvents() {
        player.eventHandler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .trackChanged(let snapshot):
                if self.capture.isRecording, let original = self.captureIdentity, snapshot.candidateKey != original.candidateKey {
                    self.finishCapture(invalidReason: "采集期间曲目发生变化，过渡归属不明；该片段未加入推荐。")
                }
                if self.isFollowPlaying {
                    self.selectedTrackID = nil
                    self.status = "当前播放：\(snapshot.title ?? "未识别歌曲")；请采集当前版本，或手动选择并核对已有录音。"
                }
            case .playbackStateChanged(let state):
                if self.capture.isRecording && (state == .paused || state == .stopped) { self.finishCapture() }
            case .positionChanged(let current, _):
                if let current {
                    if let (previous, at) = self.lastPlayerPosition, self.capture.isRecording {
                        let elapsed = Date().timeIntervalSince(at)
                        if current < previous - 0.5 || current - previous > elapsed + 2 { self.finishCapture(invalidReason: "检测到跳播；为避免把跳过或混合内容误作连续录音，此段未参与推荐。") }
                    }
                    self.lastPlayerPosition = (current, Date())
                }
            case .metadataUpdated: break
            }
        }
    }

    func beginCapture() {
        guard !busy, let database else { return }
        let app = NSWorkspace.shared.runningApplications.first { PlayerObserver.defaultBundleIdentifiers.contains($0.bundleIdentifier ?? "") }
        guard let app else { errorMessage = "请先打开网易云音乐并播放要分析的歌曲。"; return }
        busy = true
        status = "正在连接网易云进程音频…"
        Task {
            defer { busy = false }
            do {
                installPlayerEvents()
                capturedProcessingDeclaration = sharedProcessingDeclared
                capturedProcessID = app.processIdentifier
                lastPlayerPosition = nil
                let beforeStart = player.snapshot
                let url = database.directory.appendingPathComponent("Audio/capture-\(UUID().uuidString).caf")
                try await capture.start(pid: app.processIdentifier, destination: url)
                captureIdentity = player.snapshot
                captureStartedAt = Date()
                if let beforeStart, let afterStart = player.snapshot, beforeStart.candidateKey != afterStart.candidateKey {
                    finishCapture(invalidReason: "采集启动期间曲目发生变化，片段归属不明，未参与推荐。")
                    return
                }
                status = "正在采集网易云数字音频；请播放目标歌曲，至少保留 15 秒有效内容。"
            } catch { report(error) }
        }
    }

    func finishCapture(invalidReason: String? = nil) {
        guard let summary = capture.stop(), let database else { return }
        let wallClockStart = captureStartedAt
        captureStartedAt = nil
        let identity = captureIdentity
        let sharedProcessing = capturedProcessingDeclaration
        let endIdentity = player.snapshot
        captureIdentity = nil
        let nonzeroSeconds = Double(max(0, summary.capturedFrames - Int64(summary.zeroDataFrames))) / max(1, summary.sampleRate)
        let failure = invalidReason ?? summary.writerError
            ?? (summary.formatMismatchFrames > 0 ? "采集格式中途变化，此段未用于匹配。" : nil)
            ?? (!summary.hasAudioData ? "没有采到有效音频。请确认网易云正在播放，且已允许共鸣录制系统音频。" : nil)
            ?? (nonzeroSeconds < 15 ? "非零音频不足 15 秒。原始采样已保留，此段未参与匹配。" : nil)
        if let invalidReason = failure {
            var retained = TrackEntry(title: identity?.title ?? "待核对采集片段", artist: identity?.artist ?? "", neteaseID: identity?.trackID, audioPath: summary.destination.path, duration: identity?.duration, capturedSeconds: summary.duration, sampleRate: summary.sampleRate, channels: summary.channelCount, source: "中断采集", error: invalidReason)
            retained.comparisonAllowed = false
            retained.mediaStartSeconds = identity?.currentTime
            retained.wallClockStartedAt = wallClockStart
            retained.droppedFrames = summary.droppedFrames
            retained.sourceProcessID = capturedProcessID
            do { try saveTrack(retained); status = "已保留原始片段，归属不明部分未参与匹配。" } catch { report(error) }
            return
        }
        let processID = capturedProcessID
        busy = true
        analysisTask = Task {
            defer { busy = false }
            var track = TrackEntry(title: identity?.title ?? "未识别片段 \(Date().formatted(date: .omitted, time: .shortened))", artist: identity?.artist ?? "", neteaseID: identity?.trackID, sourceURL: identity?.trackURL?.absoluteString, audioPath: summary.destination.path, duration: identity?.duration, capturedSeconds: summary.duration, sampleRate: summary.sampleRate, channels: summary.channelCount, isFull: false, processingState: "播放器输出；EQ / 响度处理未核实", source: "网易云进程采集")
            track.comparisonAllowed = sharedProcessing && summary.droppedFrames == 0
            track.mediaStartSeconds = identity?.currentTime
            track.wallClockStartedAt = wallClockStart
            track.droppedFrames = summary.droppedFrames
            track.sourceProcessID = processID
            if sharedProcessing { track.processingState = "用户声明：所有候选共用相同播放处理；未作信号验证" }
            do {
                status = "正在分析采集片段 · \(track.title)"
                var isComplete = false
                if let original = identity, let end = endIdentity,
                   let exactID = original.trackID, end.trackID == exactID,
                   let startPosition = original.currentTime, let endPosition = end.currentTime,
                   let duration = original.duration, duration > 0,
                   let started = wallClockStart {
                    isComplete = startPosition <= 0.25 && endPosition >= duration - 0.25
                        && abs(summary.duration - duration) <= 0.5
                        && abs(started.timeIntervalSince(original.observedAt)) <= 0.25
                        && abs(Date().timeIntervalSince(end.observedAt)) <= 0.25
                        && summary.droppedFrames == 0
                }
                track.isFull = isComplete
                let intervals: [TimeRange]
                if let mediaStart = identity?.currentTime {
                    intervals = [try TimeRange(startSeconds: mediaStart, endSeconds: mediaStart + summary.duration)]
                } else { intervals = [] }
                // Unknown media position stays unknown; feature frame times are local PCM time.
                let coverage = try Coverage(kind: isComplete ? .complete : .partial, mediaDurationSeconds: identity?.duration, recordedDurationSeconds: summary.duration, intervals: intervals, hasUnexplainedGaps: summary.droppedFrames > 0, identityConfirmed: identity?.trackID != nil)
                let id = track.id, destination = summary.destination
                let analyzed = try await Task.detached(priority: .userInitiated) { (try SpectrumAnalyzer().analyze(fileURL: destination, coverage: coverage, recordingID: id), try LocalStore.audioDigest(destination)) }.value
                let features = analyzed.0
                track.contentSHA256 = analyzed.1
                let artifactURL = database.featureURL(id: id)
                try await Task.detached(priority: .utility) { try LocalStore.writeArtifact(features, to: artifactURL) }.value
                track.featurePath = artifactURL.path
                if summary.droppedFrames > 0 { track.error = "采集丢帧 \(summary.droppedFrames)，时间覆盖不连续" }
                try saveTrack(track)
                selectedTrackID = track.id
                status = "采集与分析完成 · \(Int(summary.sampleRate)) Hz / \(summary.channelCount) 声道 / \(String(format: "%.1f", summary.duration)) 秒片段"
                recompute()
            } catch {
                let analysisError = error
                track.error = error.localizedDescription
                do { try saveTrack(track); report(analysisError) } catch { report(error) }
            }
        }
    }
}

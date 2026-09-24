import AppKit
import Foundation
import ResonanceCore

extension AppModel {
    func startListeningServices() {
        guard automaticListeningTimer == nil, !isShuttingDown else { return }
        installPlayerEvents()
        capture.onUnexpectedStop = { [weak self] summary in
            self?.finishCapture(summaryOverride: summary)
        }
        automaticListeningPolicy.setEnabled(automaticListeningEnabled)
        if automaticListeningEnabled { player.start() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.automaticListeningTick() }
        }
        automaticListeningTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        automaticListeningTick()
    }

    func setAutomaticListeningEnabled(_ enabled: Bool) {
        guard automaticListeningEnabled != enabled else { return }
        automaticListeningEnabled = enabled
        AutomaticListeningPreference.setEnabled(enabled, in: preferences)
        automaticListeningPolicy.setEnabled(enabled)
        automaticHistorySessionID = nil
        automaticHistoryTrackID = nil
        if enabled {
            player.start()
            automaticListeningTick()
        } else {
            automaticListeningStatus = "已关闭"
            if captureIsAutomatic {
                cancelCaptureStart()
                finishCapture()
            }
        }
    }

    func prepareToQuit() {
        isShuttingDown = true
        automaticListeningTimer?.invalidate()
        automaticListeningTimer = nil
        cancelCaptureStart()
        finishCapture()
        player.stop()
    }

    func cancelCaptureStart() {
        captureRequestID = nil
        capture.cancelPendingStart()
    }

    func retryAutomaticCapture() {
        guard automaticListeningEnabled, !capture.isRecording, captureStartTask == nil else { return }
        automaticListeningPolicy.allowCaptureRetry()
        automaticListeningTick()
    }

    func automaticListeningTick() {
        guard !isShuttingDown else { return }
        // OCR may fail without immediately clearing the previous UI snapshot.
        // An old title is never evidence that the same audio is still playing.
        let snapshot = player.snapshot.flatMap { Date().timeIntervalSince($0.observedAt) <= 3 ? $0 : nil }
        // Keep the observer independent of the currently visible page. Losing
        // identity is a recording boundary even when no player event arrives.
        if snapshot == nil, captureIdentity != nil, capture.isRecording {
            finishCapture(excludingUncertainTail: "播放器或歌曲身份不可用，末尾归属不明的音频已排除。")
        }
        if snapshot == nil, captureIdentity != nil, captureRequestID != nil { cancelCaptureStart() }
        if let snapshot, capture.isRecording,
           snapshot.candidateKey == captureIdentity?.candidateKey,
           snapshot.playbackState == .playing {
            lastConfirmedCaptureSnapshot = snapshot
        }
        guard automaticListeningEnabled else { return }
        let usableIdentity = snapshot.flatMap { value -> PlayerSnapshot? in
            guard value.trackID != nil || !(value.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        let observation = automaticListeningPolicy.update(
            key: usableIdentity?.candidateKey,
            isPlaying: usableIdentity?.playbackState == .playing,
            now: Date()
        )
        guard let snapshot = usableIdentity, snapshot.playbackState == .playing,
              let sessionID = observation.sessionID else {
            automaticListeningStatus = player.permissionNeeded ? "需要辅助功能权限；尚未开始记录" :
                (snapshot == nil && player.snapshot != nil ? "播放信息已过期，采集已停止" :
                    (snapshot?.playbackState == .paused ? "播放已暂停" : player.status.message))
            return
        }
        if !captureIsAutomatic && (capture.isRecording || captureStartTask != nil) {
            automaticListeningPolicy.markCaptureAttempted()
            automaticListeningStatus = "手动采集中；自动采集等待下一播放段"
            return
        }
        if automaticHistorySessionID != sessionID {
            var track = TrackEntry(
                title: snapshot.title ?? "网易云 \(snapshot.trackID ?? "未识别歌曲")",
                artist: snapshot.artist ?? "", neteaseID: snapshot.trackID,
                sourceURL: snapshot.trackURL?.absoluteString, duration: snapshot.duration,
                source: snapshot.isCandidate ? "自动听歌记录 · 候选身份" : "自动听歌记录"
            )
            track.comparisonAllowed = false
            do {
                try saveTrack(track)
                automaticHistorySessionID = sessionID
                automaticHistoryTrackID = track.id
                if isFollowPlaying { selectedTrackID = track.id }
            } catch {
                automaticListeningStatus = "歌曲信息未保存：\(error.localizedDescription)"
                return
            }
        }
        if capture.isRecording {
            automaticListeningStatus = "正在连续采集 · \(snapshot.title ?? "当前歌曲")"
            return
        }
        guard observation.readyToCapture, captureStartTask == nil else { return }
        automaticListeningPolicy.markCaptureAttempted()
        beginCapture(automatically: true, trackID: automaticHistoryTrackID)
    }

    func installPlayerEvents() {
        player.eventHandler = { [weak self] event in
            guard let self, !self.isShuttingDown else { return }
            switch event {
            case .trackChanged(let snapshot):
                if let original = self.captureIdentity, snapshot.candidateKey != original.candidateKey {
                    self.cancelCaptureStart()
                    self.finishCapture(excludingUncertainTail: "检测到切歌；末尾归属不明的音频已排除。")
                }
                self.lastPlayerPosition = nil
                if self.isFollowPlaying { self.selectedTrackID = nil }
            case .playbackStateChanged(let state):
                if state != .playing {
                    self.cancelCaptureStart()
                    if state == .unknown {
                        self.finishCapture(excludingUncertainTail: "播放状态无法确认，末尾音频按观察时间保守截除。")
                    } else { self.finishCapture() }
                }
            case .positionChanged(let current, _):
                if let current {
                    if let (previous, at) = self.lastPlayerPosition {
                        let elapsed = Date().timeIntervalSince(at)
                        if current < previous - 0.5 || current - previous > elapsed + 2 {
                            self.cancelCaptureStart()
                            self.finishCapture(excludingUncertainTail: "检测到跳播；末尾归属不明的音频已排除，跳过区间未计为已采集。")
                            self.automaticListeningPolicy.resetForDiscontinuity()
                        }
                    }
                    self.lastPlayerPosition = (current, Date())
                }
            case .metadataUpdated: break
            case .unavailable:
                self.cancelCaptureStart()
                self.finishCapture(excludingUncertainTail: "播放器或歌曲身份不可用，末尾归属不明的音频已排除。")
            }
            self.automaticListeningTick()
        }
    }
}

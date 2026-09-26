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

    /// Select the most recent analyzed recording only when the player exposed
    /// an exact 网易云 ID. Titles and candidate metadata are never used to
    /// guess that two recordings are the same song.
    func syncFollowedPlayback() {
        guard isFollowPlaying,
              let snapshot = player.snapshot,
              Date().timeIntervalSince(snapshot.observedAt) <= 3,
              player.canCaptureCurrentSource else {
            if isFollowPlaying, !player.canCaptureCurrentSource {
                selectedTrackID = nil
            }
            return
        }
        selectFollowedCache(for: snapshot)
    }

    func automaticListeningTick() {
        guard !isShuttingDown else { return }
        // OCR may fail without immediately clearing the previous UI snapshot.
        // An old title is never evidence that the same audio is still playing.
        let snapshot = player.snapshot.flatMap { Date().timeIntervalSince($0.observedAt) <= 3 ? $0 : nil }
        // Keep the observer independent of the currently visible page. Losing
        // identity is a recording boundary even when no player event arrives.
        if snapshot != nil, captureIdentity != nil, !player.canCaptureCurrentSource {
            cancelCaptureStart()
            finishCapture(boundaryNote: "当前播放来源已不是网易云，录音在来源边界处结束。")
        }
        if snapshot == nil, captureIdentity != nil, capture.isRecording {
            finishCapture(boundaryNote: "歌曲身份不可用，按已录内容估计。")
        }
        if snapshot == nil, captureIdentity != nil, captureRequestID != nil {
            cancelCaptureStart()
        }
        guard automaticListeningEnabled else { return }
        let usableIdentity = snapshot.flatMap { value -> PlayerSnapshot? in
            guard value.trackID != nil || !(value.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }

        // System Now Playing is useful for the current-player panel, but its
        // metadata must never become a history row or drive a 网易云 capture.
        // Only the observer's verified source/PID match permits automatic
        // recording.  Reset the previous automatic session once when the
        // source leaves 网易云 so a later return cannot reuse its recording ID.
        if let snapshot = usableIdentity, !player.canCaptureCurrentSource {
            let hadAutomaticSession = captureIsAutomatic || captureRequestID != nil ||
                automaticHistorySessionID != nil || automaticHistoryTrackID != nil
            if hadAutomaticSession {
                cancelCaptureStart()
                if capture.isRecording {
                    finishCapture(boundaryNote: "当前播放来源不是网易云，自动采集已结束。")
                }
                automaticHistorySessionID = nil
                automaticHistoryTrackID = nil
                automaticListeningPolicy.resetForDiscontinuity()
            }
            automaticListeningStatus = "当前来源：\(sourceLabel(for: snapshot))；仅显示系统播放信息，未自动采集"
            return
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
            let cachedTrack = latestAnalyzedTrack(for: snapshot.trackID)
            var track = TrackEntry(
                title: snapshot.title ?? "网易云 \(snapshot.trackID ?? "未识别歌曲")",
                artist: snapshot.artist ?? "", neteaseID: snapshot.trackID,
                sourceURL: snapshot.trackURL?.absoluteString, duration: snapshot.duration,
                source: "自动听歌记录"
            )
            track.sourceBundleIdentifier = snapshot.sourceBundleIdentifier
            track.sourceApplicationName = snapshot.sourceApplicationName
            track.metadataSource = snapshot.metadataSource.rawValue
            track.sourceProcessID = snapshot.sourceProcessIdentifier
            track.mediaStartSeconds = snapshot.currentTime
            do {
                try saveTrack(track)
                automaticHistorySessionID = sessionID
                automaticHistoryTrackID = track.id
                if isFollowPlaying {
                    if let cachedTrack {
                        if selectedTrackID != cachedTrack.id {
                            selectedTrackID = cachedTrack.id
                            recompute()
                        }
                    } else {
                        selectedTrackID = track.id
                    }
                }
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
                    self.finishCapture(boundaryNote: "可能含切换尾音，按已录内容估计。")
                }
                self.lastPlayerPosition = nil
                if self.isFollowPlaying { self.selectFollowedCache(for: snapshot) }
            case .playbackStateChanged(let state):
                if state != .playing {
                    self.cancelCaptureStart()
                    if state == .unknown {
                        self.finishCapture(boundaryNote: "播放状态不明，可能含切换尾音，按已录内容估计。")
                    } else { self.finishCapture() }
                }
            case .positionChanged(let current, _):
                if let current {
                    if let (previous, at) = self.lastPlayerPosition {
                        let elapsed = Date().timeIntervalSince(at)
                        if current < previous - 0.5 || current - previous > elapsed + 2 {
                            self.cancelCaptureStart()
                            self.finishCapture(boundaryNote: "可能含跳播尾音，按已录内容估计。")
                            self.automaticListeningPolicy.resetForDiscontinuity()
                        }
                    }
                    self.lastPlayerPosition = (current, Date())
                }
            case .metadataUpdated: break
            case .unavailable:
                self.cancelCaptureStart()
                self.finishCapture(boundaryNote: "歌曲身份不可用，按已录内容估计。")
            }
            self.automaticListeningTick()
        }
    }

    private func selectFollowedCache(for snapshot: PlayerSnapshot) {
        guard isFollowPlaying, player.canCaptureCurrentSource else {
            if isFollowPlaying { selectedTrackID = nil }
            return
        }
        guard let cachedTrack = latestAnalyzedTrack(for: snapshot.trackID) else {
            selectedTrackID = nil
            return
        }
        if selectedTrackID != cachedTrack.id {
            selectedTrackID = cachedTrack.id
            recompute()
        }
    }

    private func latestAnalyzedTrack(for trackID: String?) -> TrackEntry? {
        guard let trackID = trackID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trackID.isEmpty else { return nil }
        return tracks
            .filter { $0.analyzed && $0.neteaseID?.trimmingCharacters(in: .whitespacesAndNewlines) == trackID }
            .max { $0.importedAt < $1.importedAt }
    }

    private func sourceLabel(for snapshot: PlayerSnapshot) -> String {
        if let application = snapshot.sourceApplicationName?.trimmingCharacters(in: .whitespacesAndNewlines), !application.isEmpty {
            return application
        }
        if let bundle = snapshot.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundle.isEmpty {
            return bundle
        }
        return snapshot.metadataSource.label
    }
}

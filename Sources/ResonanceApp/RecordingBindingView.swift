import SwiftUI

/// Explicitly binds an analysed recording to one imported playlist row.
///
/// A platform ID is shown as evidence for the user, but is never used to
/// select or update rows automatically.  The recording's physical analysis
/// metadata is copied only after the user selects a row and confirms the
/// recording/version statement.
struct RecordingBindingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let recording: TrackEntry

    @State private var selectedTrackID: UUID?
    @State private var confirmed = false

    init(recording: TrackEntry) {
        self.recording = recording
        _selectedTrackID = State(initialValue: nil)
    }

    private var candidates: [TrackEntry] {
        model.pendingPlaylistTracks(excluding: recording.id)
    }

    private var selectedCandidate: TrackEntry? {
        guard let selectedTrackID else { return nil }
        return candidates.first { $0.id == selectedTrackID }
    }

    private var canBind: Bool {
        recording.audioPath != nil && recording.featurePath != nil &&
            selectedCandidate != nil && confirmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            recordingCard
            candidateSection
            confirmation
            Divider()
            footer
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("确认录音归属").font(.title2.weight(.semibold))
            Text("选择这段录音对应的歌曲，将分析结果加入歌单。")
                .font(.callout)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(title: "待绑定录音", trailing: recording.coverageLabel)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.and.mic")
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.title.isEmpty ? "未命名录音" : recording.title)
                        .font(.system(size: 14, weight: .medium))
                    Text(recording.artist.isEmpty ? "艺人未知" : recording.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    if let application = recording.sourceApplicationName?.trimmingCharacters(in: .whitespacesAndNewlines), !application.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "app.badge").font(.caption2)
                            Text("来源：\(application)")
                            if let bundleID = recording.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
                                Text(bundleID).font(.caption2).lineLimit(1).truncationMode(.middle).help("来源 Bundle ID")
                            }
                        }.font(.caption2).foregroundStyle(Palette.muted)
                    } else if let bundleID = recording.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "app.badge").font(.caption2)
                            Text("来源 Bundle：\(bundleID)").lineLimit(1).truncationMode(.middle)
                        }.font(.caption2).foregroundStyle(Palette.muted)
                    }
                    HStack(spacing: 8) {
                        TinyBadge(text: recording.analyzed ? "已有频谱分析" : "尚未完成分析", color: recording.analyzed ? Palette.accent : .orange)
                        if let sampleRate = recording.sampleRate {
                            TinyBadge(text: "\(Int(sampleRate)) Hz")
                        }
                        if let channels = recording.channels {
                            TinyBadge(text: "\(channels) 声道")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(title: "导入歌单中的待采集曲目", trailing: "\(candidates.count) 行")
            if candidates.isEmpty {
                EmptyPanel(
                    icon: "music.note.list",
                    title: "没有待绑定的歌单原始行",
                    detail: "请先导入歌单，并确认其中的曲目还没有真实音频分析结果。"
                )
                .frame(minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                .frame(maxHeight: 235)
            }
        }
    }

    private func candidateRow(_ candidate: TrackEntry) -> some View {
        let selected = selectedTrackID == candidate.id
        return Button {
            selectedTrackID = candidate.id
            confirmed = false
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(candidate.title.isEmpty ? "未命名曲目" : candidate.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                        if let id = candidate.neteaseID, !id.isEmpty {
                            TinyBadge(text: "ID \(id)", color: Palette.muted)
                        } else {
                            TinyBadge(text: "无精确 ID", color: .orange)
                        }
                    }
                    Text(candidate.artist.isEmpty ? "艺人未知" : candidate.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                    Text("来源歌单：\(model.playlistName(for: candidate.sourcePlaylistID)) · 原始顺序 \(candidate.sourceOrder + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.accent.opacity(0.14) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Palette.accent.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var confirmation: some View {
        Toggle("我确认这段录音确实来自此曲目/版本", isOn: $confirmed)
            .toggleStyle(.checkbox)
            .font(.callout.weight(.medium))
            .disabled(selectedCandidate == nil)
    }

    private var footer: some View {
        HStack {
            if recording.featurePath == nil {
                Label("录音尚未完成频谱分析，不能绑定到可排序曲目。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("确认绑定") {
                guard let selectedTrackID else { return }
                guard model.bindRecording(recording, to: selectedTrackID) else { return }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canBind)
        }
    }
}

@MainActor
extension AppModel {
    /// Returns only unanalysed rows that came from an imported playlist.  The
    /// source recording is excluded by row ID; matching on `neteaseID` would
    /// incorrectly batch-bind duplicate rows or alternate recordings.
    func pendingPlaylistTracks(excluding rowID: UUID? = nil) -> [TrackEntry] {
        let importedPlaylistIDs = Set(playlists.map(\.id))
        return tracks
            .filter { track in
                guard let playlistID = track.sourcePlaylistID else { return false }
                return importedPlaylistIDs.contains(playlistID) &&
                    track.featurePath == nil &&
                    track.id != rowID
            }
            .sorted {
                if $0.sourcePlaylistID != $1.sourcePlaylistID {
                    return ($0.sourcePlaylistID?.uuidString ?? "") < ($1.sourcePlaylistID?.uuidString ?? "")
                }
                if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func playlistName(for playlistID: UUID?) -> String {
        guard let playlistID,
              let playlist = playlists.first(where: { $0.id == playlistID }) else {
            return "未关联歌单"
        }
        return playlist.name
    }

    /// Copies physical recording/analysis metadata to exactly one existing
    /// playlist row.  Identity, source URL, playlist ownership, row ID and
    /// source order remain properties of the selected target row.
    @discardableResult
    func bindRecording(_ recording: TrackEntry, to targetID: UUID) -> Bool {
        guard recording.audioPath != nil, recording.featurePath != nil else {
            status = "这段录音尚未完成分析，不能绑定为可排序曲目。"
            return false
        }
        guard let index = tracks.firstIndex(where: { $0.id == targetID }) else {
            status = "找不到要绑定的歌单原始行。"
            return false
        }
        guard let playlistID = tracks[index].sourcePlaylistID,
              playlists.contains(where: { $0.id == playlistID }) else {
            status = "只能绑定到已导入歌单中的原始行。"
            return false
        }
        guard tracks[index].featurePath == nil else {
            status = "所选歌单原始行已经有分析结果；未覆盖原数据。"
            return false
        }

        var target = tracks[index]
        // TrackEntry currently stores coverage as duration/capturedSeconds/
        // isFull/mediaStartSeconds; copy that group together with the raw
        // audio and derived feature artifact.
        target.audioPath = recording.audioPath
        target.featurePath = recording.featurePath
        target.duration = recording.duration
        target.capturedSeconds = recording.capturedSeconds
        target.sampleRate = recording.sampleRate
        target.channels = recording.channels
        target.isFull = recording.isFull
        target.processingState = recording.processingState
        target.comparisonAllowed = recording.comparisonAllowed
        target.mediaStartSeconds = recording.mediaStartSeconds
        target.wallClockStartedAt = recording.wallClockStartedAt
        target.contentSHA256 = recording.contentSHA256
        target.droppedFrames = recording.droppedFrames
        target.sourceProcessID = recording.sourceProcessID
        target.sourceBundleIdentifier = recording.sourceBundleIdentifier
        target.sourceApplicationName = recording.sourceApplicationName
        target.metadataSource = recording.metadataSource
        target.error = recording.error
        target.analysisNotes = recording.analysisNotes

        do {
            try saveTrack(target)
            selectedTrackID = target.id
            status = "已关联歌曲：\(target.title)"
            recompute()
            return true
        } catch {
            report(error)
            return false
        }
    }
}

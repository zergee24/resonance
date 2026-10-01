import Foundation
import ResonanceCore

private struct RecordingAnalysisSegmentSnapshot: Equatable, Sendable {
    let id: UUID
    let audioURL: URL
    let featureURL: URL?
    let mediaStartSeconds: Double?
    let capturedSeconds: Double
    let sampleRate: Double?
    let channels: Int?
    let droppedFrames: UInt64?
    let contentSHA256: String?
}

private struct RecordingAnalysisRequest {
    let trackID: UUID
    let queueKey: String
    let segments: [RecordingAnalysisSegmentSnapshot]
    let signature: String
    let coverage: Coverage
    let automatic: Bool
    let selectOnCompletion: Bool
    let recomputeOnCompletion: Bool
    let processingDeclared: Bool
    let identityCandidateKey: String?
}

private struct SegmentAnalysisResult: Sendable {
    let segmentID: UUID
    let feature: SpectrumFeatures
    let digest: String
    let artifactURL: URL
}

private struct DeferredShortSegment: Sendable {
    let segmentID: UUID
}

enum RecordingAnalysisSegmentAction: Sendable, Equatable {
    case analyze
    case waitForMoreAudio
}

struct RecordingAnalysisSegmentEligibility: Sendable, Equatable {
    let segmentID: UUID
    let action: RecordingAnalysisSegmentAction
    let input: SpectrumAnalyzer.InputEligibility
}

private enum SegmentAnalysisOutcome: Sendable {
    case ready(SegmentAnalysisResult)
    case deferred(DeferredShortSegment)
}

private let shortSegmentAnalysisNotePrefix = "频谱等待片段"

private struct RecordingAnalysisError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func recordingAnalysisFeatureMatches(
    _ feature: SpectrumFeatures,
    segment: RecordingAnalysisSegmentSnapshot
) -> Bool {
    guard feature.recordingID == segment.id,
          feature.sampleRate.isFinite,
          feature.durationSeconds.isFinite,
          feature.durationSeconds > 0,
          feature.channelCount > 0 else { return false }
    if let sampleRate = segment.sampleRate, abs(feature.sampleRate - sampleRate) > 0.5 { return false }
    if let channels = segment.channels, feature.channelCount != channels { return false }
    if segment.capturedSeconds > 0,
       abs(feature.durationSeconds - segment.capturedSeconds) > max(0.5, segment.capturedSeconds * 0.01) {
        return false
    }
    return true
}

extension AppModel {
    /// Shared, side-effect-free eligibility decision for the recording queue
    /// and native harnesses. A short but valid PCM file is deferred; malformed
    /// or empty files still throw and remain analysis failures.
    nonisolated static func recordingAnalysisEligibility(
        segmentID: UUID,
        audioURL: URL
    ) throws -> RecordingAnalysisSegmentEligibility {
        let input = try SpectrumAnalyzer().inputEligibility(fileURL: audioURL)
        return RecordingAnalysisSegmentEligibility(
            segmentID: segmentID,
            action: input.hasSpectrumFrame ? .analyze : .waitForMoreAudio,
            input: input
        )
    }

    /// Resumes rows whose PCM or reusable segment artifacts are on disk.
    /// Segmented rows are resumed at segment granularity; the track aggregate
    /// is rebuilt only after every segment can be analyzed or reused.
    @discardableResult
    func restorePendingAnalyses() -> Bool {
        guard !isShuttingDown, let database else { return false }
        let pending = tracks.filter { track in
            let segments = track.analysisSegments
            guard !segments.isEmpty else { return false }
            guard segments.contains(where: { canAnalyzeOrReuse($0, database: database) }) else {
                return false
            }
            // A failed later tail must not hide valid prefix segments. A row
            // with no segment artifact at all remains terminal and is skipped.
            if hasCaptureWriteFailure(track),
               track.recordingSegments == nil,
               !segments.contains(where: { artifactExists(for: $0, database: database) }) {
                return false
            }
            return needsAnalysis(track)
        }.sorted { lhs, rhs in
            // A crash can leave a complete artifact beside a row whose
            // featurePath was never committed. Claim those cheap recoveries
            // before starting any fresh FFT work.
            let leftHasArtifact = lhs.analysisSegments.contains { artifactExists(for: $0, database: database) }
            let rightHasArtifact = rhs.analysisSegments.contains { artifactExists(for: $0, database: database) }
            if leftHasArtifact != rightHasArtifact { return leftHasArtifact }
            return lhs.importedAt > rhs.importedAt
        }
        guard !pending.isEmpty else { return false }

        status = "恢复 \(pending.count) 条待分析录音…"
        for track in pending {
            enqueueAnalysis(
                track: track,
                coverage: aggregateCoverage(for: track),
                automatic: false,
                selectOnCompletion: false,
                recomputeOnCompletion: false
            )
        }

        // Recovery is a batch. Refresh the ranking once after its tail task,
        // rather than decoding and matching the whole library per recording.
        let tail = analysisTask
        Task { @MainActor [weak self] in
            await tail?.value
            guard let self, !self.isShuttingDown else { return }
            self.recompute()
        }
        return true
    }

    /// Enqueues one immutable segment snapshot. A changed segment list gets a
    /// new revision key, while an identical callback is ignored. The explicit
    /// waitForPrevious=false path is used only when a running request notices
    /// a newer segment list and hands it back to the queue after it returns.
    func enqueueAnalysis(
        track: TrackEntry,
        coverage: Coverage,
        automatic: Bool,
        selectOnCompletion: Bool,
        recomputeOnCompletion: Bool = true,
        processingDeclared: Bool = false,
        identityCandidateKey: String? = nil,
        waitForPrevious: Bool = true
    ) {
        guard let database else { return }
        let analysisSegments = track.analysisSegments
        guard analysisSegments.contains(where: { canAnalyzeOrReuse($0, database: database) }) else { return }
        let snapshots = analysisSegments.map { segment -> RecordingAnalysisSegmentSnapshot in
            let audioURL = URL(fileURLWithPath: segment.audioPath)
            let featureURL = segment.featurePath.map { URL(fileURLWithPath: $0) }
            return RecordingAnalysisSegmentSnapshot(
                id: segment.id,
                audioURL: audioURL,
                featureURL: featureURL,
                mediaStartSeconds: segment.mediaStartSeconds,
                capturedSeconds: segment.capturedSeconds,
                sampleRate: segment.sampleRate,
                channels: segment.channels,
                droppedFrames: segment.droppedFrames,
                contentSHA256: segment.contentSHA256
            )
        }
        guard !snapshots.isEmpty else { return }
        let signature = analysisSignature(snapshots)
        let segmentMissing = snapshots.contains { segment in
            !artifactExists(for: segment, database: database) && segmentNeedsSpectrum(segment)
        }
        let aggregateMissing = !aggregateArtifactExists(for: track) && snapshots.contains { segment in
            artifactExists(for: segment, database: database) || segmentNeedsSpectrum(segment)
        }
        let shortNoteMissing = snapshots.contains { segment in
            guard !artifactExists(for: segment, database: database),
                  let eligibility = try? Self.recordingAnalysisEligibility(segmentID: segment.id, audioURL: segment.audioURL),
                  eligibility.action == .waitForMoreAudio else { return false }
            return !hasShortSegmentNote(in: track.analysisNotes)
        }
        guard segmentMissing || aggregateMissing || shortNoteMissing else { return }

        let key = "track:\(track.id.uuidString)|revision:\(signature)"
        guard queuedAnalysisKeys.insert(key).inserted else { return }

        let request = RecordingAnalysisRequest(
            trackID: track.id,
            queueKey: key,
            segments: snapshots,
            signature: signature,
            coverage: coverage,
            automatic: automatic,
            selectOnCompletion: selectOnCompletion,
            recomputeOnCompletion: recomputeOnCompletion,
            processingDeclared: processingDeclared,
            identityCandidateKey: identityCandidateKey
        )
        let previous = waitForPrevious ? analysisTask : nil
        let revision = UUID()
        analysisRevision = revision
        busy = true
        analysisTask = Task { @MainActor [weak self] in
            defer { self?.queuedAnalysisKeys.remove(request.queueKey) }
            await previous?.value
            guard let self else { return }
            let newerTrack = await self.processRecordingAnalysis(request)
            if let newerTrack {
                // If a newer tail already exists, append after that tail. If
                // this request was the tail, its detached work is finished,
                // so the replacement can start without awaiting itself.
                self.enqueueAnalysis(
                    track: newerTrack,
                    coverage: self.aggregateCoverage(for: newerTrack),
                    automatic: request.automatic,
                    selectOnCompletion: request.selectOnCompletion,
                    recomputeOnCompletion: request.recomputeOnCompletion,
                    processingDeclared: request.processingDeclared,
                    identityCandidateKey: request.identityCandidateKey,
                    waitForPrevious: self.analysisRevision != revision
                )
            }
            if self.analysisRevision == revision {
                self.busy = false
            }
        }
    }

    /// Returns a newer TrackEntry when the segment snapshot changed while the
    /// detached analysis was running. The caller requeues that snapshot after
    /// this task has stopped being the tail task.
    private func processRecordingAnalysis(_ request: RecordingAnalysisRequest) async -> TrackEntry? {
        guard let database, !Task.isCancelled else { return nil }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .idleSystemSleepDisabled],
            reason: "Resonance audio analysis"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        guard let current = tracks.first(where: { $0.id == request.trackID }) else { return nil }
        guard analysisSignature(for: current) == request.signature else { return current }
        guard current.analysisSegments.allSatisfy({ canAnalyzeOrReuse($0, database: database) }) else {
            saveAnalysisFailure(for: current, error: "录音片段与已有频谱文件均不可用，无法恢复分析。", state: "音频文件不可用")
            return nil
        }

        do {
            status = "正在分析已录片段 · \(current.title)"
            var results: [SegmentAnalysisResult] = []
            results.reserveCapacity(request.segments.count)
            var deferredShortSegments: [DeferredShortSegment] = []
            for segment in request.segments {
                guard !Task.isCancelled else { return nil }
                let outcome = try await analyzeOrReuse(
                    segment: segment,
                    track: current,
                    database: database
                )
                switch outcome {
                case let .ready(result):
                    results.append(result)
                case let .deferred(shortSegment):
                    deferredShortSegments.append(shortSegment)
                }
            }

            guard let latest = tracks.first(where: { $0.id == request.trackID }) else { return nil }
            guard analysisSignature(for: latest) == request.signature else { return latest }
            var attachBase = latest
            let mergeResults = try await compactLegacyResultsWhenMixed(
                results,
                database: database
            )
            var updatedSegments = attachSegmentResults(mergeResults, to: latest.analysisSegments)
            updatedSegments = clearDeferredSegmentArtifacts(deferredShortSegments, from: updatedSegments)
            var combinedURL: URL?

            if latest.recordingSegments == nil {
                // Legacy single-file rows retain their existing shape. The
                // synthetic segment has the same stable ID as the track.
                if mergeResults.isEmpty {
                    attachBase.featurePath = nil
                } else if let result = mergeResults.first {
                    attachBase.featurePath = result.artifactURL.path
                    attachBase.contentSHA256 = result.digest
                }
            } else if latest.analysisSegments.count > 1, !mergeResults.isEmpty {
                let featureInputs = try mergeResults.map { result -> (RecordingSegment, SpectrumFeatures) in
                    guard let segment = updatedSegments.first(where: { $0.id == result.segmentID }) else {
                        throw RecordingAnalysisError(message: "频谱合并缺少对应录音片段。")
                    }
                    return (segment, result.feature)
                }
                let merged = try Self.mergeFeatures(
                    featureInputs,
                    track: attachBase,
                    coverage: aggregateCoverage(
                        for: attachBase,
                        analyzedSegmentIDs: Set(mergeResults.map(\.segmentID)),
                        forcePartial: !deferredShortSegments.isEmpty
                    )
                )
                let outputURL = database.directory.appendingPathComponent(
                    "Features/\(attachBase.id.uuidString)-combined.plist.lzfse"
                )
                let references = try mergeResults.map { result -> SpectrumSegmentReference in
                    guard let segment = updatedSegments.first(where: { $0.id == result.segmentID }),
                          let start = segment.mediaStartSeconds,
                          start.isFinite, start >= 0,
                          segment.capturedSeconds.isFinite, segment.capturedSeconds > 0,
                          result.artifactURL.deletingLastPathComponent().standardizedFileURL == outputURL.deletingLastPathComponent().standardizedFileURL else {
                        throw RecordingAnalysisError(message: "频谱合并引用缺少有效媒体起点或片段文件。")
                    }
                    return SpectrumSegmentReference(
                        fileName: result.artifactURL.lastPathComponent,
                        recordingID: result.segmentID,
                        mediaStartSeconds: start,
                        capturedSeconds: segment.capturedSeconds
                    )
                }
                try await Task.detached(priority: .utility) {
                    try LocalStore.writeSpectrumManifest(metadata: merged, segments: references, to: outputURL)
                }.value
                // Writing the aggregate is another suspension point. Re-read
                // the row before attaching it so a newly appended tail cannot
                // be overwritten by this older snapshot.
                guard let latestAfterWrite = tracks.first(where: { $0.id == request.trackID }) else { return nil }
                guard analysisSignature(for: latestAfterWrite) == request.signature else { return latestAfterWrite }
                attachBase = latestAfterWrite
                updatedSegments = attachSegmentResults(mergeResults, to: latestAfterWrite.analysisSegments)
                updatedSegments = clearDeferredSegmentArtifacts(deferredShortSegments, from: updatedSegments)
                combinedURL = outputURL
            }

            var updated = attachBase
            if latest.recordingSegments == nil {
                // Legacy rows were attached above. A short-only row keeps its
                // PCM metadata but deliberately has no feature artifact.
            } else if latest.analysisSegments.count == 1, let result = mergeResults.first {
                updated.recordingSegments = updatedSegments
                updated.featurePath = result.artifactURL.path
                updated.contentSHA256 = result.digest
            } else if !mergeResults.isEmpty {
                guard let combinedURL else {
                    throw RecordingAnalysisError(message: "频谱合并结果未生成。")
                }
                updated.recordingSegments = updatedSegments
                updated.featurePath = combinedURL.path
                // The per-segment digests remain authoritative. A combined
                // track has no single raw file digest, so do not mislabel one
                // segment's digest as the aggregate.
                updated.contentSHA256 = nil
            } else if mergeResults.isEmpty {
                updated.recordingSegments = updatedSegments
                updated.featurePath = nil
                updated.contentSHA256 = nil
            }

            updated.audioPath = updated.audioPath ?? updatedSegments.first?.audioPath
            updated.capturedSeconds = uniqueCapturedSeconds(updatedSegments)
            updated.sampleRate = updated.sampleRate ?? updatedSegments.first?.sampleRate
            updated.channels = updated.channels ?? updatedSegments.first?.channels
            updated.droppedFrames = sumDroppedFrames(updatedSegments)
            updated.isFull = deferredShortSegments.isEmpty && (updated.recordingSegments == nil
                ? updated.isFull
                : hasExactFullCoverage(track: updated, intervals: RecordingContinuation.unionCoverage(for: updatedSegments)))
            updated.analysisNotes = updatedShortSegmentNotes(
                existing: updated.analysisNotes,
                deferredSegments: deferredShortSegments
            )
            if !deferredShortSegments.isEmpty {
                updated.processingState = mergeResults.isEmpty
                    ? "等待后续录音：片段短于频谱窗"
                    : "已分析有效采集段；短片段等待后续录音"
            } else {
                updated.processingState = request.processingDeclared ? "用户备注：播放处理与候选一致" : "播放器输出；处理链未知"
            }
            updated.error = nil
            try saveTrack(updated)
            scheduleRawAudioCacheReclaim(afterAnalyzedTrackID: request.trackID)
            finishAnalysisUI(
                for: updated,
                request: request,
                duration: mergedDuration(of: updated),
                deferredShortSegments: deferredShortSegments
            )
            return nil
        } catch is CancellationError {
            // The persisted waiting row remains recoverable on the next launch.
            return nil
        } catch {
            saveAnalysisFailure(for: current, error: error.localizedDescription, state: "频谱分析失败，等待下次恢复")
            return nil
        }
    }

    private func analyzeOrReuse(
        segment: RecordingAnalysisSegmentSnapshot,
        track: TrackEntry,
        database: LocalStore
    ) async throws -> SegmentAnalysisOutcome {
        let defaultURL = database.featureURL(id: segment.id)
        let compactURL = database.directory.appendingPathComponent(
            "Features/\(segment.id.uuidString)-compact.plist.lzfse"
        )
        let candidates = [compactURL, segment.featureURL, defaultURL].compactMap { $0 }
            .reduce(into: [URL]()) { values, candidate in
                if !values.contains(candidate) { values.append(candidate) }
            }
        let reuseAttempt = await Task.detached(priority: .utility) {
            () -> (SegmentAnalysisOutcome?, String?) in
            var lastFailure: String?
            for candidate in candidates {
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                do {
                    let feature = try LocalStore.readArtifact(SpectrumFeatures.self, from: candidate)
                    guard recordingAnalysisFeatureMatches(feature, segment: segment) else {
                        lastFailure = "片段频谱元数据与录音片段不匹配"
                        continue
                    }
                    let digest = segment.contentSHA256 ?? (try? LocalStore.audioDigest(segment.audioURL)) ?? ""
                    return (
                        .ready(SegmentAnalysisResult(segmentID: segment.id, feature: feature, digest: digest, artifactURL: candidate)),
                        nil
                    )
                } catch {
                    lastFailure = error.localizedDescription
                }
            }
            return (nil, lastFailure)
        }.value
        if let reused = reuseAttempt.0 { return reused }

        guard isUsableAudioFile(segment.audioURL) else {
            if let failure = reuseAttempt.1, !failure.isEmpty {
                throw RecordingAnalysisError(message: "已有频谱文件损坏或不兼容：\(failure)")
            }
            throw RecordingAnalysisError(message: "录音片段文件不存在，且没有可复用的频谱文件。")
        }

        let eligibility = try Self.recordingAnalysisEligibility(segmentID: segment.id, audioURL: segment.audioURL)
        guard eligibility.action == .analyze else {
            return .deferred(
                DeferredShortSegment(
                    segmentID: segment.id
                )
            )
        }

        let importedFull = track.recordingSegments == nil && track.isFull
        let intervals: [TimeRange]
        if importedFull, segment.capturedSeconds > 0 {
            intervals = [try TimeRange(startSeconds: 0, endSeconds: segment.capturedSeconds)]
        } else {
            intervals = []
        }
        let coverage = try Coverage(
            kind: importedFull ? .complete : .partial,
            mediaDurationSeconds: track.duration,
            recordedDurationSeconds: segment.capturedSeconds,
            intervals: intervals,
            hasUnexplainedGaps: (segment.droppedFrames ?? 0) > 0,
            identityConfirmed: track.neteaseID != nil
        )
        let id = segment.id
        let audioURL = segment.audioURL
        let analyzed = try await Task.detached(priority: .userInitiated) {
            let feature = try SpectrumAnalyzer().analyzeCompact(fileURL: audioURL, coverage: coverage, recordingID: id)
            let digest = try LocalStore.audioDigest(audioURL)
            try LocalStore.writeCompactSpectrum(feature, to: defaultURL)
            return (feature, digest)
        }.value
        return .ready(SegmentAnalysisResult(segmentID: id, feature: analyzed.0, digest: analyzed.1, artifactURL: defaultURL))
    }

    nonisolated static func mergeFeatures(
        _ inputs: [(RecordingSegment, SpectrumFeatures)],
        track: TrackEntry,
        coverage: Coverage
    ) throws -> SpectrumFeatures {
        guard let first = inputs.first else { throw RecordingAnalysisError(message: "没有可合并的频谱片段。") }
        for (_, feature) in inputs.dropFirst() {
            guard compatible(first.1, feature) else {
                throw RecordingAnalysisError(message: "录音片段的采样率、频率网格或声道格式不一致，暂不合并。")
            }
        }

        if inputs.count > 1,
           inputs.contains(where: { $0.0.mediaStartSeconds == nil || !($0.0.mediaStartSeconds?.isFinite ?? false) }) {
            throw RecordingAnalysisError(message: "多段录音缺少可靠的媒体起点，暂不合并。")
        }

        struct TimedFrame {
            let start: Double
            let frame: SpectrumFrame
        }
        var frames: [SpectrumFrame] = []
        var priorSegmentIntervals: [TimeRange] = []
        let orderedInputs = inputs.sorted { lhs, rhs in
            (lhs.0.mediaStartSeconds ?? 0) < (rhs.0.mediaStartSeconds ?? 0)
        }
        for (segment, feature) in orderedInputs {
            let offset = segment.mediaStartSeconds ?? 0
            let segmentDuration = segment.capturedSeconds.isFinite && segment.capturedSeconds > 0
                ? segment.capturedSeconds
                : feature.durationSeconds
            let segmentEnd = offset + segmentDuration
            let segmentInterval = try? TimeRange(startSeconds: offset, endSeconds: segmentEnd)
            for frame in feature.frames {
                let start = offset + frame.startTimeSeconds
                let frameDuration = Double(frame.sampleCount) / feature.sampleRate
                let end = start + frameDuration
                let center = (start + end) / 2
                guard start.isFinite, end.isFinite, end > start else { continue }
                // STFT windows overlap inside one segment by design. Keep all
                // of them. Only discard a later segment frame whose center is
                // inside a media interval already owned by an earlier segment.
                let overlapsEarlierSegment = priorSegmentIntervals.contains {
                    center > $0.startSeconds && center < $0.endSeconds
                }
                guard !overlapsEarlierSegment else { continue }
                frames.append(SpectrumFrame(
                    startTimeSeconds: start,
                    sampleCount: frame.sampleCount,
                    powerSpectralDensityByChannel: frame.powerSpectralDensityByChannel
                ))
            }
            if let segmentInterval { priorSegmentIntervals.append(segmentInterval) }
        }
        guard !frames.isEmpty else { throw RecordingAnalysisError(message: "合并后没有有效频谱帧。") }
        frames.sort { $0.startTimeSeconds < $1.startTimeSeconds }
        let duration = max(
            track.duration ?? 0,
            frames.map { $0.startTimeSeconds + Double($0.sampleCount) / first.1.sampleRate }.max() ?? 0
        )
        return SpectrumFeatures(
            recordingID: track.id,
            sampleRate: first.1.sampleRate,
            channelCount: first.1.channelCount,
            frequencyBinsHz: first.1.frequencyBinsHz,
            frames: frames,
            durationSeconds: duration,
            coverage: coverage,
            validMinHz: first.1.validMinHz,
            validMaxHz: first.1.validMaxHz,
            frequencyValidity: first.1.frequencyValidity,
            format: first.1.format,
            parameters: first.1.parameters,
            analyzerVersion: first.1.analyzerVersion,
            frequencyCellEdgesHz: first.1.frequencyCellEdgesHz,
            compactStorage: first.1.compactStorage
        )
    }

    nonisolated static func compatible(_ lhs: SpectrumFeatures, _ rhs: SpectrumFeatures) -> Bool {
        guard abs(lhs.sampleRate - rhs.sampleRate) <= 0.5,
              lhs.channelCount == rhs.channelCount,
              lhs.format == rhs.format,
              lhs.parameters == rhs.parameters,
              lhs.frequencyBinsHz.count == rhs.frequencyBinsHz.count,
              lhs.frequencyBinsHz.enumerated().allSatisfy({ index, value in abs(value - rhs.frequencyBinsHz[index]) <= 1e-6 }),
              lhs.frequencyCellEdgesHz == rhs.frequencyCellEdgesHz,
              lhs.compactStorage == rhs.compactStorage,
              lhs.analyzerVersion == rhs.analyzerVersion else { return false }
        return true
    }

    private func compactLegacyResultsWhenMixed(
        _ results: [SegmentAnalysisResult],
        database: LocalStore
    ) async throws -> [SegmentAnalysisResult] {
        guard results.contains(where: { $0.feature.compactStorage != nil }),
              results.contains(where: { $0.feature.compactStorage == nil }) else {
            return results
        }
        let directory = database.directory
        return try await Task.detached(priority: .utility) {
            try results.map { result in
                guard result.feature.compactStorage == nil else { return result }
                let compact = try CompactSpectrum.compact(result.feature)
                let outputURL = directory.appendingPathComponent(
                    "Features/\(result.segmentID.uuidString)-compact.plist.lzfse"
                )
                try LocalStore.writeCompactSpectrum(compact, to: outputURL)
                return SegmentAnalysisResult(
                    segmentID: result.segmentID,
                    feature: compact,
                    digest: result.digest,
                    artifactURL: outputURL
                )
            }
        }.value
    }

    private func attachSegmentResults(_ results: [SegmentAnalysisResult], to segments: [RecordingSegment]) -> [RecordingSegment] {
        segments.map { segment in
            guard let result = results.first(where: { $0.segmentID == segment.id }) else { return segment }
            var updated = segment
            updated.featurePath = result.artifactURL.path
            updated.contentSHA256 = result.digest.isEmpty ? segment.contentSHA256 : result.digest
            updated.sampleRate = result.feature.sampleRate
            updated.channels = result.feature.channelCount
            return updated
        }
    }

    private func clearDeferredSegmentArtifacts(
        _ deferred: [DeferredShortSegment],
        from segments: [RecordingSegment]
    ) -> [RecordingSegment] {
        let deferredIDs = Set(deferred.map(\.segmentID))
        guard !deferredIDs.isEmpty else { return segments }
        return segments.map { segment in
            guard deferredIDs.contains(segment.id) else { return segment }
            var updated = segment
            updated.featurePath = nil
            // The digest describes the retained PCM, not its eligibility for
            // spectral analysis. Deferring FFT work does not invalidate it.
            return updated
        }
    }

    private func aggregateCoverage(
        for track: TrackEntry,
        analyzedSegmentIDs: Set<UUID>? = nil,
        forcePartial: Bool = false
    ) -> Coverage {
        let segments = track.analysisSegments.filter { segment in
            analyzedSegmentIDs == nil || analyzedSegmentIDs!.contains(segment.id)
        }
        var intervals = RecordingContinuation.unionCoverage(for: segments)
        let legacyCaptured: Double? = track.capturedSeconds.isFinite && track.capturedSeconds > 0
            ? track.capturedSeconds
            : track.duration
        if intervals.isEmpty, track.recordingSegments == nil,
           track.isFull,
           let captured = legacyCaptured, captured > 0 {
            intervals = [try! TimeRange(startSeconds: 0, endSeconds: captured)]
        }
        let covered = intervals.reduce(0) { $0 + $1.durationSeconds }
        let complete = !forcePartial && hasExactFullCoverage(track: track, intervals: intervals)
        return try! Coverage(
            kind: complete ? .complete : .partial,
            mediaDurationSeconds: track.duration,
            recordedDurationSeconds: covered > 0 ? covered : segments.reduce(0) { $0 + max(0, $1.capturedSeconds) },
            intervals: intervals,
            hasUnexplainedGaps: segments.contains { ($0.droppedFrames ?? 0) > 0 },
            identityConfirmed: track.neteaseID != nil
        )
    }

    private func hasExactFullCoverage(track: TrackEntry, intervals: [TimeRange]) -> Bool {
        guard let duration = track.duration, duration.isFinite, duration > 0,
              intervals.count == 1,
              let interval = intervals.first else { return false }
        // The continuation tolerance is deliberately looser for deciding
        // whether another capture is worthwhile. It must not label a track
        // complete when a real media-time gap remains.
        return interval.startSeconds <= 0.5 && interval.endSeconds >= duration - 0.5
    }

    private func needsAnalysis(_ track: TrackEntry) -> Bool {
        guard let database else { return false }
        let segments = track.analysisSegments
        let missingSegment = segments.contains {
            !artifactExists(for: $0, database: database) && segmentNeedsSpectrum($0)
        }
        let aggregateMissing = !aggregateArtifactExists(for: track) && segments.contains {
            artifactExists(for: $0, database: database) || segmentNeedsSpectrum($0)
        }
        let shortNoteMissing = segments.contains { segment in
            guard !artifactExists(for: segment, database: database),
                  let eligibility = try? Self.recordingAnalysisEligibility(segmentID: segment.id, audioURL: URL(fileURLWithPath: segment.audioPath)),
                  eligibility.action == .waitForMoreAudio else { return false }
            return !hasShortSegmentNote(in: track.analysisNotes)
        }
        return missingSegment || aggregateMissing || shortNoteMissing
    }

    private func segmentNeedsSpectrum(_ segment: RecordingAnalysisSegmentSnapshot) -> Bool {
        guard let eligibility = try? Self.recordingAnalysisEligibility(segmentID: segment.id, audioURL: segment.audioURL) else {
            // Empty, corrupt, or unreadable audio must remain an analysis
            // failure rather than being silently classified as short.
            return true
        }
        return eligibility.action == .analyze
    }

    private func segmentNeedsSpectrum(_ segment: RecordingSegment) -> Bool {
        guard let eligibility = try? Self.recordingAnalysisEligibility(segmentID: segment.id, audioURL: URL(fileURLWithPath: segment.audioPath)) else {
            return true
        }
        return eligibility.action == .analyze
    }

    private func hasShortSegmentNote(in notes: [String]?) -> Bool {
        notes?.contains(where: { $0.hasPrefix(shortSegmentAnalysisNotePrefix) }) ?? false
    }

    private func updatedShortSegmentNotes(
        existing: [String]?,
        deferredSegments: [DeferredShortSegment]
    ) -> [String]? {
        let oldNotes = existing ?? []
        var retained = oldNotes.filter { !$0.hasPrefix(shortSegmentAnalysisNotePrefix) }
        if !deferredSegments.isEmpty {
            retained.append(
                "\(shortSegmentAnalysisNotePrefix)：存在短于分析窗的录音片段，已保留原始 PCM，等待后续录音，不生成频谱。"
            )
        }
        return retained.isEmpty ? nil : retained
    }

    private func artifactExists(for segment: RecordingAnalysisSegmentSnapshot, database: LocalStore) -> Bool {
        if let featureURL = segment.featureURL, FileManager.default.fileExists(atPath: featureURL.path) { return true }
        return FileManager.default.fileExists(atPath: database.featureURL(id: segment.id).path)
    }

    private func artifactExists(for segment: RecordingSegment, database: LocalStore) -> Bool {
        if let featurePath = segment.featurePath, FileManager.default.fileExists(atPath: featurePath) { return true }
        return FileManager.default.fileExists(atPath: database.featureURL(id: segment.id).path)
    }

    private func canAnalyzeOrReuse(_ segment: RecordingSegment, database: LocalStore) -> Bool {
        isUsableAudioFile(URL(fileURLWithPath: segment.audioPath)) || artifactExists(for: segment, database: database)
    }

    private func aggregateArtifactExists(for track: TrackEntry) -> Bool {
        guard let featurePath = track.featurePath else { return false }
        return FileManager.default.fileExists(atPath: featurePath)
    }

    private func analysisSignature(for track: TrackEntry) -> String {
        let snapshots = track.analysisSegments.map { segment in
            return "\(segment.id.uuidString)=\(segment.audioPath)=\(segment.mediaStartSeconds ?? -1)=\(segment.capturedSeconds)=\(segment.sampleRate ?? -1)=\(segment.channels ?? -1)=\(segment.droppedFrames ?? 0)"
        }
        return snapshots.joined(separator: "|")
    }

    private func analysisSignature(_ segments: [RecordingAnalysisSegmentSnapshot]) -> String {
        segments.map { segment in
            "\(segment.id.uuidString)=\(segment.audioURL.standardizedFileURL.path)=\(segment.mediaStartSeconds ?? -1)=\(segment.capturedSeconds)=\(segment.sampleRate ?? -1)=\(segment.channels ?? -1)=\(segment.droppedFrames ?? 0)"
        }.joined(separator: "|")
    }

    private func uniqueCapturedSeconds(_ segments: [RecordingSegment]) -> Double {
        let intervals = RecordingContinuation.unionCoverage(for: segments)
        if !intervals.isEmpty { return intervals.reduce(0) { $0 + $1.durationSeconds } }
        return segments.reduce(0) { $0 + max(0, $1.capturedSeconds) }
    }

    private func sumDroppedFrames(_ segments: [RecordingSegment]) -> UInt64? {
        let values = segments.compactMap(\.droppedFrames)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private func mergedDuration(of track: TrackEntry) -> Double {
        track.duration ?? track.analysisSegments.reduce(0) { $0 + max(0, $1.capturedSeconds) }
    }

    private func isUsableAudioFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private func hasCaptureWriteFailure(_ track: TrackEntry) -> Bool {
        let state = track.processingState.trimmingCharacters(in: .whitespacesAndNewlines)
        return state == "采集写入失败" || state == "采集格式无效" || state == "采集无有效音频"
    }

    private func finishAnalysisUI(
        for track: TrackEntry,
        request: RecordingAnalysisRequest,
        duration: Double,
        deferredShortSegments: [DeferredShortSegment] = []
    ) {
        if request.selectOnCompletion,
           !request.automatic || (isFollowPlaying && player.snapshot?.candidateKey == request.identityCandidateKey) {
            selectedTrackID = track.id
        }
        status = deferredShortSegments.isEmpty
            ? "已分析全部有效采集段 · \(String(format: "%.1f", duration)) 秒 · \(track.coverageLabel)"
            : (track.analyzed
                ? "已分析有效采集段 · 另有短片段等待后续录音 · \(track.coverageLabel)"
                : "已保留短录音，等待后续录音 · \(track.coverageLabel)")
        if request.automatic {
            automaticListeningStatus = deferredShortSegments.isEmpty
                ? "已保存：\(track.title) · \(track.coverageLabel)"
                : "已保存：\(track.title) · 短片段等待后续录音"
        }
        if request.recomputeOnCompletion, !isShuttingDown {
            recompute()
        }
    }

    private func saveAnalysisFailure(for track: TrackEntry, error: String, state: String) {
        var current = tracks.first(where: { $0.id == track.id }) ?? track
        current.error = error
        current.processingState = state
        do {
            try saveTrack(current)
            if current.source == "自动听歌采集" {
                automaticListeningStatus = "音频已保留：\(error)"
            } else if !isShuttingDown {
                report(RecordingAnalysisError(message: error))
            }
        } catch {
            report(error)
        }
    }

    private func scheduleRawAudioCacheReclaim(afterAnalyzedTrackID trackID: UUID) {
        // Capture start/stop and track attachment are MainActor-serialized.
        // A live capture owns a new UUID destination that is not yet in the
        // library snapshot; the current capture track ID protects its older
        // segments while other closed, verified tracks may still be pruned.
        guard let database, captureStartTask == nil else { return }
        guard rawAudioCacheTask == nil else { return }
        let directory = database.directory
        let pendingTrackIDs = pendingAnalysisTrackIDs(including: trackID)
        var protectedTrackIDs = pendingTrackIDs
        if let captureTrackID { protectedTrackIDs.insert(captureTrackID) }
        let snapshot = RawAudioCache.snapshot(tracks: tracks, pendingTrackIDs: protectedTrackIDs)
        rawAudioCacheTask = Task { @MainActor [weak self] in
            defer { self?.rawAudioCacheTask = nil }
            guard let self,
                  !self.isShuttingDown,
                  self.captureStartTask == nil else { return }
            let plan = try? await Task.detached(priority: .utility) {
                try RawAudioCache.makePlan(directory: directory, snapshot: snapshot)
            }.value
            guard let plan, !plan.candidates.isEmpty,
                  !self.isShuttingDown,
                  self.captureStartTask == nil else { return }
            var currentPending = self.pendingAnalysisTrackIDs(including: trackID)
            if let captureTrackID = self.captureTrackID { currentPending.insert(captureTrackID) }
            let currentSnapshot = RawAudioCache.snapshot(tracks: self.tracks, pendingTrackIDs: currentPending)
            let result = RawAudioCache.apply(
                plan,
                directory: directory,
                snapshot: currentSnapshot
            )
            guard result.deletedBytes > 0 else { return }
            self.status = "频谱已保存；已释放 \(result.deletedBytes) 字节原始音频，已保存频谱仍可使用。"
        }
    }

    private func pendingAnalysisTrackIDs(including trackID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [trackID]
        for key in queuedAnalysisKeys where key.hasPrefix("track:") {
            let value = key.dropFirst("track:".count).split(separator: "|", maxSplits: 1).first
            if let value, let id = UUID(uuidString: String(value)) { result.insert(id) }
        }
        return result
    }
}

import Foundation
import Darwin
import SQLite3
import ResonanceCore

private enum CompactLibraryError: Error, CustomStringConvertible {
    case usage(String)
    case source(String)
    case output(String)
    case database(String)
    case incomplete(String)

    var description: String {
        switch self {
        case let .usage(message): return "用法错误：\(message)"
        case let .source(message): return "源资料库错误：\(message)"
        case let .output(message): return "输出副本错误：\(message)"
        case let .database(message): return "SQLite 错误：\(message)"
        case let .incomplete(message): return "转换未完成：\(message)"
        }
    }
}

private struct CompactLibraryArtifactHeader: Decodable {
    let resonanceArtifact: String?
}

private enum RunMode: String, Codable {
    case plan
    case convert
}

private struct Options {
    let mode: RunMode
    let source: URL
    let output: URL?
    let bandsPerOctave: Int
}

private struct DocumentRow {
    let kind: String
    let id: String
    let body: Data
    let modified: Double
}

private struct TrackSegmentInput {
    let id: UUID?
    let featurePath: String?
    let mediaStartSeconds: Double?
    let capturedSeconds: Double?
    let audioPath: String?
}

private struct AliasSegmentIdentity {
    let id: UUID?
    let featurePath: String?
    let mediaStartSeconds: Double?
    let capturedSeconds: Double?
}

private struct AliasTrackIdentity {
    let trackID: UUID
    let neteaseID: String?
    let album: String?
    let duration: Double?
    let capturedSeconds: Double?
    let processingState: String?
    let comparisonAllowed: Bool?
    let contentSHA256: String?
    let topFeaturePath: String?
    let segments: [AliasSegmentIdentity]?
}

private struct TrackInput {
    let row: DocumentRow
    let body: [String: Any]
    let trackIDString: String?
    let trackID: UUID?
    let topFeaturePath: String?
    let capturedSeconds: Double?
    let segments: [TrackSegmentInput]?
    let identity: AliasTrackIdentity?
}

private struct LeafReport: Codable {
    let sourcePath: String
    var outputPath: String?
    var status: String
    var recordingIDs: [String]
    var sourceBytes: Int64?
    var outputBytes: Int64?
    var frameCount: Int?
    var verified: Bool
    var maxQuantizationErrorDB: Double?
    var error: String?
}

private struct TrackReport: Codable {
    let rowID: String
    let trackID: String?
    var status: String
    var sourceFeaturePaths: [String]
    var outputFeaturePath: String?
    var actualSegmentCount: Int
    var deferredSegmentCount: Int
    var retainedAudioPaths: [String]
    var sourceArtifactRecordingID: String?
    var error: String?
}

private struct SizeSummary: Codable {
    var uniqueFeaturePaths: Int = 0
    var existingFeatureFiles: Int = 0
    var missingFeatureFiles: Int = 0
    var sourceFeatureBytes: Int64 = 0
    var outputFeatureBytes: Int64 = 0
    var uniqueManifestPaths: Int = 0
    var existingManifestFiles: Int = 0
    var missingManifestFiles: Int = 0
    var sourceManifestBytes: Int64 = 0
    var outputManifestBytes: Int64 = 0
    var uniqueAudioPaths: Int = 0
    var existingAudioFiles: Int = 0
    var missingAudioFiles: Int = 0
    var retainedExternalAudioBytes: Int64 = 0
    var copiedAudioBytes: Int64 = 0
    var eligibleAudioFilesWithConvertedFeatures: Int = 0
    var eligibleAudioBytesWithConvertedFeatures: Int64 = 0
}

private struct RunReport: Codable {
    let tool: String
    let version: Int
    let mode: RunMode
    let source: String
    let output: String?
    let completed: Bool
    let verified: Bool
    let verifiedLeafCount: Int
    let verifiedManifestCount: Int
    let maxQuantizationErrorDB: Double?
    let sourceOpenedReadOnly: Bool
    let originalAudioRetainedExternal: Bool
    let bandsPerOctave: Int
    let documentCounts: [String: Int]
    let size: SizeSummary
    let leaves: [LeafReport]
    let tracks: [TrackReport]
    let errors: [String]
    let warnings: [String]
}

private struct LeafState {
    let sourceURL: URL
    let outputURL: URL
    let recordingID: UUID?
    let sourceRecordingID: UUID?
    let frameCount: Int
    let durationSeconds: Double
    let sampleRate: Double
    let hopLength: Int
    var recordingIDs: [String]
    var sourceBytes: Int64?
    var outputBytes: Int64?
}

private struct TrackConversion {
    let report: TrackReport
    let body: Data?
}

private final class SQLiteConnection {
    private(set) var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool) throws {
        var opened: OpaquePointer?
        let flags: Int32 = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let opened { sqlite3_close(opened) }
            throw CompactLibraryError.database(message)
        }
        self.handle = opened
        if readOnly {
            try execute("PRAGMA query_only=ON")
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw CompactLibraryError.database("数据库连接已关闭") }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw CompactLibraryError.database(message)
        }
    }

    func documents() throws -> [DocumentRow] {
        guard let handle else { throw CompactLibraryError.database("数据库连接已关闭") }
        var statement: OpaquePointer?
        let sql = "SELECT kind,id,body,modified FROM documents ORDER BY kind,id"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CompactLibraryError.database(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [DocumentRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw CompactLibraryError.database(String(cString: sqlite3_errmsg(handle)))
            }
            guard let kindBytes = sqlite3_column_text(statement, 0),
                  let idBytes = sqlite3_column_text(statement, 1),
                  let bodyBytes = sqlite3_column_blob(statement, 2) else {
                throw CompactLibraryError.database("documents 行缺少 kind、id 或 body")
            }
            let bodyLength = Int(sqlite3_column_bytes(statement, 2))
            rows.append(DocumentRow(
                kind: String(cString: kindBytes),
                id: String(cString: idBytes),
                body: Data(bytes: bodyBytes, count: bodyLength),
                modified: sqlite3_column_double(statement, 3)
            ))
        }
        return rows
    }

    func updateTrackBodies(_ updates: [(id: String, body: Data)]) throws {
        guard let handle else { throw CompactLibraryError.database("数据库连接已关闭") }
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer {
            if !committed { try? execute("ROLLBACK") }
        }

        var statement: OpaquePointer?
        let sql = "UPDATE documents SET body=? WHERE kind='tracks' AND id=?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CompactLibraryError.database(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for update in updates {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            _ = update.body.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(update.body.count), transient)
            }
            sqlite3_bind_text(statement, 2, update.id, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CompactLibraryError.database(String(cString: sqlite3_errmsg(handle)))
            }
            guard sqlite3_changes(handle) == 1 else {
                throw CompactLibraryError.database("未能按原始 id 更新 tracks 文档：\(update.id)")
            }
        }
        try execute("COMMIT")
        committed = true
    }

    func backup(to destination: SQLiteConnection) throws {
        guard let sourceHandle = handle, let destinationHandle = destination.handle else {
            throw CompactLibraryError.database("数据库连接已关闭")
        }
        guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
            throw CompactLibraryError.database(String(cString: sqlite3_errmsg(destinationHandle)))
        }
        var status: Int32 = SQLITE_OK
        var busyAttempts = 0
        repeat {
            status = sqlite3_backup_step(backup, -1)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                busyAttempts += 1
                if busyAttempts > 100 {
                    _ = sqlite3_backup_finish(backup)
                    throw CompactLibraryError.database("源 SQLite 持续忙或锁定，未生成副本")
                }
                usleep(10_000)
            }
        } while status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED
        let finishStatus = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw CompactLibraryError.database(String(cString: sqlite3_errmsg(destinationHandle)))
        }
    }
}

private final class ConversionContext {
    let sourceDirectory: URL
    let outputDirectory: URL
    let featuresDirectory: URL
    let bandsPerOctave: Int
    var leaves: [String: LeafState] = [:]
    var leafReports: [String: LeafReport] = [:]
    var usedOutputNames: Set<String> = []
    var outputManifestBytes: Int64 = 0
    var aliasGroups: [String: [AliasTrackIdentity]] = [:]
    var verifiedLeafCount = 0
    var verifiedManifestCount = 0
    var maxQuantizationErrorDB: Double?
    var trackReports: [TrackReport] = []
    var errors: [String] = []
    var warnings: [String] = []
    var pendingTrackUpdates: [(id: String, body: Data)] = []

    init(sourceDirectory: URL, outputDirectory: URL, bandsPerOctave: Int) throws {
        self.sourceDirectory = sourceDirectory
        self.outputDirectory = outputDirectory
        self.featuresDirectory = outputDirectory.appendingPathComponent("Features", isDirectory: true)
        self.bandsPerOctave = bandsPerOctave
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: featuresDirectory, withIntermediateDirectories: false)
    }

    func configureAliasEvidence(_ tracks: [TrackInput]) {
        var groups: [String: [AliasTrackIdentity]] = [:]
        for track in tracks {
            guard let identity = track.identity else { continue }
            let paths = collectFeaturePaths(track, includeAggregate: true)
                .map { canonicalPath(resolveSourcePath($0)) }
            for path in Set(paths) {
                if !groups[path, default: []].contains(where: { $0.trackID == identity.trackID }) {
                    groups[path, default: []].append(identity)
                }
            }
        }
        aliasGroups = groups
    }

    func convert(_ track: TrackInput) -> TrackConversion {
        autoreleasepool { convertOne(track) }
    }

    private func convertOne(_ track: TrackInput) -> TrackConversion {
        var report = TrackReport(
            rowID: track.row.id,
            trackID: track.trackIDString,
            status: "unchanged",
            sourceFeaturePaths: [],
            outputFeaturePath: nil,
            actualSegmentCount: 0,
            deferredSegmentCount: 0,
            retainedAudioPaths: retainedAudioPaths(for: track),
            sourceArtifactRecordingID: nil,
            error: nil
        )

        do {
            guard let trackID = track.trackID else {
                throw CompactLibraryError.source("tracks/\(track.row.id) 的 id 不是有效 UUID")
            }

            if let segments = track.segments {
                var mutableSegments: [[String: Any]] = []
                guard let rawSegments = track.body["recordingSegments"] as? [Any], rawSegments.count == segments.count else {
                    throw CompactLibraryError.source("tracks/\(track.row.id) 的 recordingSegments 不是可保留的 JSON 数组")
                }
                var references: [SpectrumSegmentReference] = []
                var outputPaths: [String] = []

                for (index, inputSegment) in segments.enumerated() {
                    guard var rawSegment = rawSegments[index] as? [String: Any] else {
                        throw CompactLibraryError.source("tracks/\(track.row.id) 的 recordingSegments[\(index)] 不是 JSON 对象")
                    }
                    if let audioPath = inputSegment.audioPath, !audioPath.isEmpty {
                        _ = audioPath
                    }
                    guard let sourceFeaturePath = inputSegment.featurePath, !sourceFeaturePath.isEmpty else {
                        report.deferredSegmentCount += 1
                        mutableSegments.append(rawSegment)
                        continue
                    }
                    guard let segmentID = inputSegment.id else {
                        throw CompactLibraryError.source("tracks/\(track.row.id) 的片段 \(index) 缺少有效 recordingID")
                    }
                    guard let mediaStart = inputSegment.mediaStartSeconds,
                          mediaStart.isFinite, mediaStart >= 0 else {
                        throw CompactLibraryError.source("tracks/\(track.row.id) 的片段 \(index) 缺少有效 mediaStartSeconds")
                    }
                    guard let captured = inputSegment.capturedSeconds,
                          captured.isFinite, captured > 0 else {
                        throw CompactLibraryError.source("tracks/\(track.row.id) 的片段 \(index) 缺少有效 capturedSeconds")
                    }

                    let sourceURL = resolveSourcePath(sourceFeaturePath)
                    let leaf = try ensureLeaf(
                        sourceURL: sourceURL,
                        expectedRecordingID: segmentID,
                        expectedCapturedSeconds: captured,
                        aliasCandidate: track
                    )
                    report.sourceFeaturePaths.append(sourceURL.path)
                    report.actualSegmentCount += 1
                    outputPaths.append(leaf.outputURL.path)
                    rawSegment["featurePath"] = leaf.outputURL.path
                    mutableSegments.append(rawSegment)
                    references.append(SpectrumSegmentReference(
                        fileName: leaf.outputURL.lastPathComponent,
                        recordingID: segmentID,
                        mediaStartSeconds: mediaStart,
                        capturedSeconds: captured
                    ))
                }

                guard report.actualSegmentCount > 0 else {
                    let hasAudio = !report.retainedAudioPaths.isEmpty
                    report.status = hasAudio ? "deferred_unanalyzed" : "unchanged_metadata"
                    report.error = hasAudio
                        ? "有原始音频但没有已保存频谱；保留源路径且不计为已分析"
                        : nil
                    if hasAudio { warnings.append(trackError(report)) }
                    return TrackConversion(report: report, body: nil)
                }

                var updatedBody = track.body
                updatedBody["recordingSegments"] = mutableSegments
                if segments.count > 1 {
                    guard let aggregatePath = track.topFeaturePath, !aggregatePath.isEmpty else {
                        throw CompactLibraryError.source("tracks/\(track.row.id) 的多片段记录缺少 combined manifest")
                    }
                    let aggregateURL = resolveSourcePath(aggregatePath)
                    let aggregateFeature = try readAggregateFeature(
                        aggregateURL,
                        expectedTrackID: trackID,
                        aliasCandidate: track
                    )
                    if aggregateFeature.recordingID != trackID {
                        report.sourceArtifactRecordingID = aggregateFeature.recordingID?.uuidString
                    }
                    if report.deferredSegmentCount > 0, aggregateFeature.coverage.kind == .complete {
                        throw CompactLibraryError.source("源 combined coverage=complete 但仍有 deferred 片段")
                    }
                    let compactAggregate = try CompactSpectrum.compact(
                        aggregateFeature,
                        bandsPerOctave: bandsPerOctave
                    )
                    let manifestMetadata = compactAggregate.recordingID == trackID
                        ? compactAggregate
                        : replacingRecordingID(in: compactAggregate, with: trackID)
                    let combinedURL = outputDirectory.appendingPathComponent(
                        "Features/\(trackID.uuidString)-combined.plist.lzfse"
                    )
                    try LocalStore.writeSpectrumManifest(
                        metadata: manifestMetadata,
                        segments: references,
                        to: combinedURL
                    )
                    let combined = try LocalStore.readArtifact(SpectrumFeatures.self, from: combinedURL)
                    guard !combined.frames.isEmpty else {
                        throw CompactLibraryError.source("tracks/\(track.row.id) 的新 combined manifest 没有可回读帧")
                    }
                    let manifestErrorDB = try verifyStoredSpectrum(
                        expected: manifestMetadata,
                        actual: combined,
                        label: "combined \(combinedURL.path)"
                    )
                    verifiedManifestCount += 1
                    maxQuantizationErrorDB = maxQuantizationErrorDB.map { max($0, manifestErrorDB) } ?? manifestErrorDB
                    outputManifestBytes += fileSize(combinedURL) ?? 0
                    updatedBody["featurePath"] = combinedURL.path
                    report.outputFeaturePath = combinedURL.path
                    report.status = report.deferredSegmentCount == 0 ? "converted" : "converted_partial"
                } else if let outputPath = outputPaths.first {
                    updatedBody["featurePath"] = outputPath
                    report.outputFeaturePath = outputPath
                    report.status = report.deferredSegmentCount == 0 ? "converted" : "converted_partial"
                }

                report.error = report.deferredSegmentCount > 0
                    ? "部分片段仍为 deferred；未将其计入已分析覆盖"
                    : nil
                let encoded = try encodeJSON(updatedBody)
                pendingTrackUpdates.append((id: track.row.id, body: encoded))
                if report.deferredSegmentCount > 0 { warnings.append(trackError(report)) }
                return TrackConversion(report: report, body: encoded)
            }

            guard let sourceFeaturePath = track.topFeaturePath, !sourceFeaturePath.isEmpty else {
                let hasAudio = !report.retainedAudioPaths.isEmpty
                report.status = hasAudio ? "deferred_unanalyzed" : "unchanged_metadata"
                report.error = hasAudio
                    ? "有原始音频但没有已保存频谱；保留源路径且不计为已分析"
                    : nil
                if hasAudio { warnings.append(trackError(report)) }
                return TrackConversion(report: report, body: nil)
            }
            let sourceURL = resolveSourcePath(sourceFeaturePath)
            let leaf = try ensureLeaf(
                sourceURL: sourceURL,
                expectedRecordingID: trackID,
                expectedCapturedSeconds: track.capturedSeconds,
                aliasCandidate: track
            )
            report.sourceFeaturePaths = [sourceURL.path]
            report.actualSegmentCount = 1
            if leaf.sourceRecordingID != trackID {
                report.sourceArtifactRecordingID = leaf.sourceRecordingID?.uuidString
            }
            report.outputFeaturePath = leaf.outputURL.path
            report.status = "converted"
            var updatedBody = track.body
            updatedBody["featurePath"] = leaf.outputURL.path
            let encoded = try encodeJSON(updatedBody)
            pendingTrackUpdates.append((id: track.row.id, body: encoded))
            return TrackConversion(report: report, body: encoded)
        } catch {
            report.status = "failed"
            report.error = String(describing: error)
            errors.append(trackError(report))
            return TrackConversion(report: report, body: nil)
        }
    }

    func writeCheckpoint() throws {
        let checkpoint = RunReport(
            tool: "compact-library",
            version: 1,
            mode: .convert,
            source: sourceDirectory.path,
            output: outputDirectory.path,
            completed: false,
            verified: verifiedLeafCount > 0 || verifiedManifestCount > 0,
            verifiedLeafCount: verifiedLeafCount,
            verifiedManifestCount: verifiedManifestCount,
            maxQuantizationErrorDB: maxQuantizationErrorDB,
            sourceOpenedReadOnly: true,
            originalAudioRetainedExternal: true,
            bandsPerOctave: bandsPerOctave,
            documentCounts: [:],
            size: SizeSummary(),
            leaves: leafReports.values.sorted { $0.sourcePath < $1.sourcePath },
            tracks: trackReports,
            errors: errors,
            warnings: warnings
        )
        try writeJSON(checkpoint, to: outputDirectory.appendingPathComponent("compact-library-checkpoint.json"))
    }

    func finalizeReport(documentCounts: [String: Int], size: SizeSummary) throws -> RunReport {
        let report = RunReport(
            tool: "compact-library",
            version: 1,
            mode: .convert,
            source: sourceDirectory.path,
            output: outputDirectory.path,
            completed: errors.isEmpty,
            verified: verifiedLeafCount > 0 || verifiedManifestCount > 0,
            verifiedLeafCount: verifiedLeafCount,
            verifiedManifestCount: verifiedManifestCount,
            maxQuantizationErrorDB: maxQuantizationErrorDB,
            sourceOpenedReadOnly: true,
            originalAudioRetainedExternal: true,
            bandsPerOctave: bandsPerOctave,
            documentCounts: documentCounts,
            size: size,
            leaves: leafReports.values.sorted { $0.sourcePath < $1.sourcePath },
            tracks: trackReports,
            errors: errors,
            warnings: warnings
        )
        try writeJSON(report, to: outputDirectory.appendingPathComponent("compact-library-report.json"))
        return report
    }

    private func ensureLeaf(
        sourceURL: URL,
        expectedRecordingID: UUID,
        expectedCapturedSeconds: Double? = nil,
        aliasCandidate: TrackInput? = nil
    ) throws -> LeafState {
        let sourceKey = canonicalPath(sourceURL)
        let outputKey = leafMapKey(sourceKey, recordingID: expectedRecordingID)
        if var existing = leaves[outputKey] {
            if let expectedCapturedSeconds,
               abs(expectedCapturedSeconds - existing.durationSeconds) > max(1, Double(existing.hopLength)) / existing.sampleRate {
                throw CompactLibraryError.source("同一原 leaf path 被多个不一致 capturedSeconds 引用：\(sourceKey)")
            }
            let id = expectedRecordingID.uuidString
            if !existing.recordingIDs.contains(id) { existing.recordingIDs.append(id) }
            leaves[outputKey] = existing
            leafReports[outputKey]?.recordingIDs = existing.recordingIDs
            return existing
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            let report = LeafReport(sourcePath: sourceKey, outputPath: nil, status: "failed", recordingIDs: [expectedRecordingID.uuidString], sourceBytes: nil, outputBytes: nil, frameCount: nil, verified: false, maxQuantizationErrorDB: nil, error: "原 leaf 文件不存在")
            leafReports[outputKey] = report
            throw CompactLibraryError.source("原 leaf 文件不存在：\(sourceKey)")
        }
        guard artifactMarker(at: sourceURL) == nil else {
            throw CompactLibraryError.source("原 featurePath 不是 leaf，而是 manifest：\(sourceKey)")
        }
        let features = try LocalStore.readArtifact(SpectrumFeatures.self, from: sourceURL)
        guard !features.frames.isEmpty else {
            throw CompactLibraryError.source("原 leaf 没有频谱帧（0frame）：\(sourceKey)")
        }
        let sourceRecordingID = features.recordingID
        let needsLegacyAliasClone = sourceRecordingID != expectedRecordingID
        if needsLegacyAliasClone {
            guard let aliasCandidate,
                  aliasCandidate.segments == nil,
                  let sourceRecordingID,
                  aliasAllowed(sourceURL: sourceURL, candidate: aliasCandidate, sourceRecordingID: sourceRecordingID) else {
                throw CompactLibraryError.source("原 leaf recordingID 与 TrackEntry 不一致：\(sourceKey)")
            }
        }
        if let expectedCapturedSeconds {
            let tolerance = max(1, Double(features.parameters.hopLength)) / features.sampleRate
            guard features.sampleRate.isFinite, features.sampleRate > 0,
                  features.durationSeconds.isFinite, features.durationSeconds > 0,
                  abs(expectedCapturedSeconds - features.durationSeconds) <= tolerance else {
                throw CompactLibraryError.source("原 leaf duration 与 capturedSeconds 不一致：\(sourceKey)")
            }
        }

        let compacted = try CompactSpectrum.compact(features, bandsPerOctave: bandsPerOctave)
        let outputFeatures = needsLegacyAliasClone
            ? replacingRecordingID(in: compacted, with: expectedRecordingID)
            : compacted
        let outputURL = allocateOutputURL(for: sourceURL, recordingID: expectedRecordingID)
        try LocalStore.writeCompactSpectrum(outputFeatures, to: outputURL)
        let reread = try LocalStore.readArtifact(SpectrumFeatures.self, from: outputURL)
        guard !reread.frames.isEmpty, let actualRecordingID = reread.recordingID else {
            throw CompactLibraryError.source("紧凑 leaf 写入后无法按原 ID 回读：\(sourceKey)")
        }
        guard actualRecordingID == expectedRecordingID else {
            throw CompactLibraryError.source("紧凑 leaf 写入后 recordingID 与 TrackEntry 不一致：\(sourceKey)")
        }
        let quantizationErrorDB = try verifyStoredSpectrum(expected: outputFeatures, actual: reread, label: "leaf \(sourceKey)")
        verifiedLeafCount += 1
        maxQuantizationErrorDB = maxQuantizationErrorDB.map { max($0, quantizationErrorDB) } ?? quantizationErrorDB

        let sourceBytes = fileSize(sourceURL)
        let outputBytes = fileSize(outputURL)
        let state = LeafState(
            sourceURL: sourceURL,
            outputURL: outputURL,
            recordingID: actualRecordingID,
            sourceRecordingID: sourceRecordingID,
            frameCount: reread.frames.count,
            durationSeconds: reread.durationSeconds,
            sampleRate: reread.sampleRate,
            hopLength: reread.parameters.hopLength,
            recordingIDs: Array(Set([sourceRecordingID?.uuidString, actualRecordingID.uuidString].compactMap { $0 })).sorted(),
            sourceBytes: sourceBytes,
            outputBytes: outputBytes
        )
        leaves[outputKey] = state
        leafReports[outputKey] = LeafReport(
            sourcePath: sourceKey,
            outputPath: outputURL.path,
            status: "converted",
            recordingIDs: state.recordingIDs,
            sourceBytes: sourceBytes,
            outputBytes: outputBytes,
            frameCount: reread.frames.count,
            verified: true,
            maxQuantizationErrorDB: quantizationErrorDB,
            error: nil
        )
        return state
    }

    private func verifyStoredSpectrum(
        expected: SpectrumFeatures,
        actual: SpectrumFeatures,
        label: String
    ) throws -> Double {
        guard actual.recordingID == expected.recordingID,
              actual.sampleRate == expected.sampleRate,
              actual.channelCount == expected.channelCount,
              actual.frequencyBinsHz == expected.frequencyBinsHz,
              actual.frequencyCellEdgesHz == expected.frequencyCellEdgesHz,
              actual.compactStorage == expected.compactStorage,
              actual.durationSeconds == expected.durationSeconds,
              actual.coverage == expected.coverage,
              actual.validMinHz == expected.validMinHz,
              actual.validMaxHz == expected.validMaxHz,
              actual.frequencyValidity == expected.frequencyValidity,
              actual.format == expected.format,
              actual.parameters == expected.parameters,
              actual.analyzerVersion == expected.analyzerVersion,
              actual.frames.count == expected.frames.count else {
            throw CompactLibraryError.source("\(label) 回读后元数据、覆盖、网格、窗参数或帧数量变化")
        }

        var maximumErrorDB = 0.0
        for (index, pair) in zip(expected.frames, actual.frames).enumerated() {
            let expectedFrame = pair.0
            let actualFrame = pair.1
            guard abs(expectedFrame.startTimeSeconds - actualFrame.startTimeSeconds) <= 1e-12,
                  expectedFrame.sampleCount == actualFrame.sampleCount,
                  actualFrame.powerSpectralDensityByChannel.count == expectedFrame.powerSpectralDensityByChannel.count else {
                throw CompactLibraryError.source("\(label) 回读后第 \(index) 帧时间、窗长度或声道数变化")
            }
            for channelIndex in expectedFrame.powerSpectralDensityByChannel.indices {
                let expectedChannel = expectedFrame.powerSpectralDensityByChannel[channelIndex]
                let actualChannel = actualFrame.powerSpectralDensityByChannel[channelIndex]
                guard actualChannel.count == expectedChannel.count else {
                    throw CompactLibraryError.source("\(label) 回读后第 \(index) 帧频率网格长度变化")
                }
                for (expectedValue, actualValue) in zip(expectedChannel, actualChannel) {
                    guard expectedValue.isFinite, expectedValue >= 0,
                          actualValue.isFinite, actualValue >= 0 else {
                        throw CompactLibraryError.source("\(label) 回读后出现非有限或负 PSD")
                    }
                    if expectedValue == 0 {
                        guard actualValue == 0 else {
                            throw CompactLibraryError.source("\(label) 零 PSD sentinel 回读变化")
                        }
                    } else {
                        guard actualValue > 0 else {
                            throw CompactLibraryError.source("\(label) 正 PSD 回读为零")
                        }
                        let errorDB = abs(10 * log10(actualValue / expectedValue))
                        guard errorDB.isFinite, errorDB <= 0.005 + 1e-9 else {
                            throw CompactLibraryError.source("\(label) PSD 量化误差超过 0.005 dB")
                        }
                        maximumErrorDB = max(maximumErrorDB, errorDB)
                    }
                }
            }
        }
        return maximumErrorDB
    }

    private func replacingRecordingID(in source: SpectrumFeatures, with recordingID: UUID) -> SpectrumFeatures {
        SpectrumFeatures(
            recordingID: recordingID,
            sampleRate: source.sampleRate,
            channelCount: source.channelCount,
            frequencyBinsHz: source.frequencyBinsHz,
            frames: source.frames,
            durationSeconds: source.durationSeconds,
            coverage: source.coverage,
            validMinHz: source.validMinHz,
            validMaxHz: source.validMaxHz,
            frequencyValidity: source.frequencyValidity,
            format: source.format,
            parameters: source.parameters,
            analyzerVersion: source.analyzerVersion,
            frequencyCellEdgesHz: source.frequencyCellEdgesHz,
            compactStorage: source.compactStorage
        )
    }

    private func readAggregateFeature(
        _ url: URL,
        expectedTrackID: UUID,
        aliasCandidate: TrackInput
    ) throws -> SpectrumFeatures {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CompactLibraryError.source("原 combined manifest 不存在：\(url.path)")
        }
        let feature = try LocalStore.readArtifact(SpectrumFeatures.self, from: url)
        guard !feature.frames.isEmpty else {
            throw CompactLibraryError.source("原 combined manifest 没有频谱帧（0frame）：\(url.path)")
        }
        if feature.recordingID != expectedTrackID {
            guard let sourceRecordingID = feature.recordingID,
                  aliasAllowed(sourceURL: url, candidate: aliasCandidate, sourceRecordingID: sourceRecordingID) else {
                throw CompactLibraryError.source("原 combined manifest recordingID 与 TrackEntry 不一致：\(url.path)")
            }
        }
        return feature
    }

    private func allocateOutputURL(for sourceURL: URL, recordingID: UUID) -> URL {
        let originalName = sourceURL.lastPathComponent
        let base: String
        if originalName.hasSuffix(".plist.lzfse") {
            base = String(originalName.dropLast(".plist.lzfse".count)) + ".compact.plist.lzfse"
        } else {
            base = originalName + ".compact.plist.lzfse"
        }
        var candidate = base
        if usedOutputNames.contains(candidate) {
            candidate = (base as NSString).deletingPathExtension + "-alias-\(recordingID.uuidString.prefix(12)).lzfse"
        }
        var serial = 2
        while usedOutputNames.contains(candidate) {
            candidate = (base as NSString).deletingPathExtension + "-\(serial).lzfse"
            serial += 1
        }
        usedOutputNames.insert(candidate)
        return featuresDirectory.appendingPathComponent(candidate)
    }

    private func resolveSourcePath(_ path: String) -> URL {
        let raw = URL(fileURLWithPath: path)
        if raw.path.hasPrefix("/") { return raw.standardizedFileURL }
        return sourceDirectory.appendingPathComponent(path).standardizedFileURL
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func retainedAudioPaths(for track: TrackInput) -> [String] {
        var paths: [String] = []
        if let path = track.body["audioPath"] as? String, !path.isEmpty { paths.append(path) }
        if let path = track.body["rawAudioPath"] as? String, !path.isEmpty { paths.append(path) }
        for segment in track.segments ?? [] {
            if let path = segment.audioPath, !path.isEmpty { paths.append(path) }
        }
        return Array(Set(paths)).sorted()
    }

    private func trackError(_ report: TrackReport) -> String {
        "tracks/\(report.rowID): \(report.error ?? report.status)"
    }

    private func leafMapKey(_ sourcePath: String, recordingID: UUID) -> String {
        "\(sourcePath)#\(recordingID.uuidString)"
    }

    private func aliasAllowed(
        sourceURL: URL,
        candidate: TrackInput,
        sourceRecordingID: UUID
    ) -> Bool {
        guard let candidateIdentity = candidate.identity,
              candidateIdentity.trackID != sourceRecordingID else { return true }
        let sourcePath = canonicalPath(sourceURL)
        guard let members = aliasGroups[sourcePath], members.count > 1 else { return false }

        let candidateIsTop = candidateIdentity.topFeaturePath.map { canonicalPath(resolveSourcePath($0)) == sourcePath } ?? false
        let candidateSegment = candidateIdentity.segments?.first { segment in
            guard let path = segment.featurePath else { return false }
            return canonicalPath(resolveSourcePath(path)) == sourcePath
        }
        let owner: AliasTrackIdentity?
        if candidateIsTop {
            owner = members.first { member in
                member.trackID == sourceRecordingID
                    && (member.topFeaturePath.map { canonicalPath(resolveSourcePath($0)) == sourcePath } ?? false)
            }
        } else if let candidateSegment {
            owner = members.first { member in
                member.segments?.contains { segment in
                    segment.id == sourceRecordingID
                        && (segment.featurePath.map { canonicalPath(resolveSourcePath($0)) == sourcePath } ?? false)
                } ?? false
            }
            guard candidateSegment.id == sourceRecordingID else { return false }
        } else {
            return false
        }
        guard let owner, owner.trackID != candidateIdentity.trackID,
              sameAliasMetadata(owner, candidateIdentity) else { return false }

        if candidateIsTop {
            switch (owner.segments, candidateIdentity.segments) {
            case (nil, nil):
                // A legacy, unsegmented alias has no child recording ID to
                // prove identity. Require the persisted content hash.
                guard let ownerHash = owner.contentSHA256,
                      let candidateHash = candidateIdentity.contentSHA256,
                      !ownerHash.isEmpty, ownerHash == candidateHash else { return false }
                return true
            case let (ownerSegments?, candidateSegments?):
                return sameSegmentLayout(ownerSegments, candidateSegments)
            default:
                return false
            }
        }

        guard let ownerSegments = owner.segments,
              let candidateSegments = candidateIdentity.segments else { return false }
        return sameSegmentLayout(ownerSegments, candidateSegments)
    }

    private func sameAliasMetadata(_ lhs: AliasTrackIdentity, _ rhs: AliasTrackIdentity) -> Bool {
        if let left = lhs.neteaseID, let right = rhs.neteaseID, left != right { return false }
        if let left = lhs.contentSHA256, let right = rhs.contentSHA256, left != right { return false }
        guard lhs.album == rhs.album,
              sameNumber(lhs.duration, rhs.duration),
              sameNumber(lhs.capturedSeconds, rhs.capturedSeconds),
              lhs.processingState == rhs.processingState,
              lhs.comparisonAllowed == rhs.comparisonAllowed else { return false }
        return true
    }

    private func sameSegmentLayout(_ lhs: [AliasSegmentIdentity], _ rhs: [AliasSegmentIdentity]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard left.id == right.id,
                  sameNumber(left.mediaStartSeconds, right.mediaStartSeconds),
                  sameNumber(left.capturedSeconds, right.capturedSeconds),
                  let leftPath = left.featurePath,
                  let rightPath = right.featurePath else { return false }
            return canonicalPath(resolveSourcePath(leftPath)) == canonicalPath(resolveSourcePath(rightPath))
        }
    }

    private func sameNumber(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return abs(left - right) <= 1e-9
        default: return false
        }
    }
}

@main
private struct CompactLibraryTool {
    static func main() throws {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            switch options.mode {
            case .plan:
                let report = try makePlan(options)
                let data = try JSONEncoder.pretty.encode(report)
                print(String(decoding: data, as: UTF8.self))
            case .convert:
                let report = try convert(options)
                let data = try JSONEncoder.pretty.encode(report)
                print(String(decoding: data, as: UTF8.self))
                if !report.completed {
                    throw CompactLibraryError.incomplete("详见 \(options.output!.appendingPathComponent("compact-library-report.json").path)")
                }
            }
        } catch {
            FileHandle.standardError.write(Data(("compact-library: \(String(describing: error))\n").utf8))
            exit(1)
        }
    }

    private static func makePlan(_ options: Options) throws -> RunReport {
        let sourceDB = options.source.appendingPathComponent("library.sqlite")
        let connection = try SQLiteConnection(url: sourceDB, readOnly: true)
        let rows = try connection.documents()
        var documentCounts: [String: Int] = [:]
        var featurePaths = Set<String>()
        var manifestPaths = Set<String>()
        var audioPaths = Set<String>()
        var errors: [String] = []
        for row in rows {
            documentCounts[row.kind, default: 0] += 1
            guard row.kind == "tracks" else { continue }
            do {
                let track = try parseTrack(row)
                featurePaths.formUnion(collectFeaturePaths(track, includeAggregate: false).map { resolve(path: $0, source: options.source) })
                manifestPaths.formUnion(collectManifestPaths(track).map { resolve(path: $0, source: options.source) })
                audioPaths.formUnion(trackAudioPaths(track).map { resolve(path: $0, source: options.source) })
            } catch {
                errors.append("tracks/\(row.id): \(String(describing: error))")
            }
        }

        var size = SizeSummary()
        size.uniqueFeaturePaths = featurePaths.count
        for path in featurePaths {
            if let bytes = fileSize(URL(fileURLWithPath: path)) {
                size.existingFeatureFiles += 1
                size.sourceFeatureBytes += bytes
            } else {
                size.missingFeatureFiles += 1
            }
        }
        size.uniqueManifestPaths = manifestPaths.count
        for path in manifestPaths {
            if let bytes = fileSize(URL(fileURLWithPath: path)) {
                size.existingManifestFiles += 1
                size.sourceManifestBytes += bytes
            } else {
                size.missingManifestFiles += 1
            }
        }
        size.uniqueAudioPaths = audioPaths.count
        for path in audioPaths {
            if let bytes = fileSize(URL(fileURLWithPath: path)) {
                size.existingAudioFiles += 1
                size.retainedExternalAudioBytes += bytes
            } else {
                size.missingAudioFiles += 1
            }
        }
        return RunReport(
            tool: "compact-library",
            version: 1,
            mode: .plan,
            source: options.source.path,
            output: nil,
            completed: errors.isEmpty,
            verified: false,
            verifiedLeafCount: 0,
            verifiedManifestCount: 0,
            maxQuantizationErrorDB: nil,
            sourceOpenedReadOnly: true,
            originalAudioRetainedExternal: true,
            bandsPerOctave: options.bandsPerOctave,
            documentCounts: documentCounts,
            size: size,
            leaves: [],
            tracks: [],
            errors: errors,
            warnings: ["plan 只读取 SQLite 与文件 stat；未解码频谱，也未写入输出。"]
        )
    }

    private static func convert(_ options: Options) throws -> RunReport {
        guard let output = options.output else { throw CompactLibraryError.usage("--convert 必须提供 --output") }
        let sourceDB = options.source.appendingPathComponent("library.sqlite")
        guard FileManager.default.fileExists(atPath: sourceDB.path) else {
            throw CompactLibraryError.source("缺少 library.sqlite：\(sourceDB.path)")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw CompactLibraryError.output("输出目录必须是全新的不存在目录：\(output.path)")
        }

        let sourceConnection = try SQLiteConnection(url: sourceDB, readOnly: true)
        let rows = try sourceConnection.documents()
        var documentCounts: [String: Int] = [:]
        for row in rows { documentCounts[row.kind, default: 0] += 1 }

        let context = try ConversionContext(sourceDirectory: options.source, outputDirectory: output, bandsPerOctave: options.bandsPerOctave)
        let outputDB = output.appendingPathComponent("library.sqlite")
        let destinationConnection = try SQLiteConnection(url: outputDB, readOnly: false)
        try sourceConnection.backup(to: destinationConnection)

        var inputs: [TrackInput] = []
        for row in rows where row.kind == "tracks" {
            do {
                inputs.append(try parseTrack(row))
            } catch {
                let report = TrackReport(rowID: row.id, trackID: nil, status: "failed", sourceFeaturePaths: [], outputFeaturePath: nil, actualSegmentCount: 0, deferredSegmentCount: 0, retainedAudioPaths: [], sourceArtifactRecordingID: nil, error: String(describing: error))
                context.trackReports.append(report)
                context.errors.append("tracks/\(row.id): \(String(describing: error))")
            }
        }
        context.configureAliasEvidence(inputs)
        var eligibleAudioPaths = Set<String>()
        for input in inputs.sorted(by: { $0.row.id < $1.row.id }) {
            let result = context.convert(input)
            context.trackReports.append(result.report)
            if result.report.status == "converted" || result.report.status == "converted_partial" {
                eligibleAudioPaths.formUnion(trackAudioPaths(input).map { resolve(path: $0, source: options.source) })
            }
            try context.writeCheckpoint()
        }

        if !context.pendingTrackUpdates.isEmpty {
            try destinationConnection.updateTrackBodies(context.pendingTrackUpdates)
        }

        var size = SizeSummary()
        size.uniqueFeaturePaths = context.leaves.count
        var countedSourceLeafPaths = Set<String>()
        for leaf in context.leaves.values {
            let sourcePath = leaf.sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
            if countedSourceLeafPaths.insert(sourcePath).inserted {
                if leaf.sourceBytes != nil { size.existingFeatureFiles += 1; size.sourceFeatureBytes += leaf.sourceBytes! }
                else { size.missingFeatureFiles += 1 }
            }
            if leaf.outputBytes != nil { size.outputFeatureBytes += leaf.outputBytes! }
        }
        let manifestPaths = Set(inputs.compactMap { track -> String? in
            guard track.segments?.count ?? 0 > 1, let path = track.topFeaturePath else { return nil }
            return resolve(path: path, source: options.source)
        })
        size.uniqueManifestPaths = manifestPaths.count
        for path in manifestPaths {
            if let bytes = fileSize(URL(fileURLWithPath: path)) {
                size.existingManifestFiles += 1
                size.sourceManifestBytes += bytes
            } else { size.missingManifestFiles += 1 }
        }
        size.outputManifestBytes = context.outputManifestBytes
        var audioPaths = Set<String>()
        for input in inputs { audioPaths.formUnion(trackAudioPaths(input).map { resolve(path: $0, source: options.source) }) }
        size.uniqueAudioPaths = audioPaths.count
        for path in audioPaths {
            if let bytes = fileSize(URL(fileURLWithPath: path)) {
                size.existingAudioFiles += 1
                size.retainedExternalAudioBytes += bytes
            } else { size.missingAudioFiles += 1 }
        }
        for path in eligibleAudioPaths {
            if let bytes = fileSize(URL(fileURLWithPath: path)) {
                size.eligibleAudioFilesWithConvertedFeatures += 1
                size.eligibleAudioBytesWithConvertedFeatures += bytes
            }
        }
        let report = try context.finalizeReport(documentCounts: documentCounts, size: size)
        return report
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private func parseOptions(_ arguments: [String]) throws -> Options {
    var mode: RunMode = .plan
    var sourcePath: String?
    var outputPath: String?
    var bandsPerOctave = 48
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--plan":
            guard mode == .plan else { throw CompactLibraryError.usage("--plan 与 --convert 不能同时使用") }
            mode = .plan
        case "--convert":
            guard mode == .plan, !arguments.contains("--plan") else { throw CompactLibraryError.usage("--plan 与 --convert 不能同时使用") }
            mode = .convert
        case "--source":
            index += 1
            guard index < arguments.count else { throw CompactLibraryError.usage("--source 缺少路径") }
            sourcePath = arguments[index]
        case "--output":
            index += 1
            guard index < arguments.count else { throw CompactLibraryError.usage("--output 缺少路径") }
            outputPath = arguments[index]
        case "--bands-per-octave":
            index += 1
            guard index < arguments.count, let parsed = Int(arguments[index]), parsed > 0 else {
                throw CompactLibraryError.usage("--bands-per-octave 必须是正整数")
            }
            bandsPerOctave = parsed
        case "--help", "-h":
            print("用法：compact-library --source <Resonance目录> [--plan | --convert --output <新目录>] [--bands-per-octave 48]")
            exit(0)
        default:
            throw CompactLibraryError.usage("未知参数：\(arguments[index])")
        }
        index += 1
    }
    guard let sourcePath else { throw CompactLibraryError.usage("必须提供 --source") }
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    var output: URL?
    if let outputPath {
        output = URL(fileURLWithPath: outputPath).standardizedFileURL
    }
    guard FileManager.default.fileExists(atPath: source.path) else { throw CompactLibraryError.source("目录不存在：\(source.path)") }
    guard FileManager.default.fileExists(atPath: source.appendingPathComponent("library.sqlite").path) else { throw CompactLibraryError.source("目录中缺少 library.sqlite") }
    if mode == .convert {
        guard let output else { throw CompactLibraryError.usage("--convert 必须提供 --output") }
        let outputPath = canonicalOutputPath(output)
        let protectedPaths = [
            canonicalOutputPath(source),
            canonicalOutputPath(source.appendingPathComponent("Audio", isDirectory: true)),
            canonicalOutputPath(source.appendingPathComponent("Features", isDirectory: true))
        ]
        for protectedPath in protectedPaths where outputPath == protectedPath || outputPath.hasPrefix(protectedPath + "/") {
            throw CompactLibraryError.output("输出目录不能覆盖源资料库、Audio 或 Features：\(output.path)")
        }
    }
    return Options(mode: mode, source: source, output: output, bandsPerOctave: bandsPerOctave)
}

private func parseTrack(_ row: DocumentRow) throws -> TrackInput {
    guard let object = try JSONSerialization.jsonObject(with: row.body) as? [String: Any] else {
        throw CompactLibraryError.source("body 不是 JSON 对象")
    }
    let idString = object["id"] as? String ?? row.id
    if let bodyID = object["id"] as? String,
       bodyID != row.id,
       UUID(uuidString: bodyID) != UUID(uuidString: row.id) {
        throw CompactLibraryError.source("body id 与 SQLite documents.id 不一致")
    }
    let trackID = UUID(uuidString: idString)
    let topFeaturePath = nonEmptyString(object["featurePath"])
    var segments: [TrackSegmentInput]?
    if let rawValue = object["recordingSegments"], !(rawValue is NSNull) {
        guard let rawSegments = rawValue as? [Any] else {
            throw CompactLibraryError.source("recordingSegments 不是 JSON 数组")
        }
        segments = try rawSegments.enumerated().map { index, value in
            guard let raw = value as? [String: Any] else {
                throw CompactLibraryError.source("recordingSegments[\(index)] 不是 JSON 对象")
            }
            let idString = raw["id"] as? String
            return TrackSegmentInput(
                id: idString.flatMap { UUID(uuidString: $0) },
                featurePath: nonEmptyString(raw["featurePath"]),
                mediaStartSeconds: finiteDouble(raw["mediaStartSeconds"]),
                capturedSeconds: finiteDouble(raw["capturedSeconds"]),
                audioPath: nonEmptyString(raw["audioPath"])
            )
        }
    }
    let identity = trackID.map { id in
        AliasTrackIdentity(
            trackID: id,
            neteaseID: nonEmptyString(object["neteaseID"]),
            album: object["album"] as? String,
            duration: finiteDouble(object["duration"]),
            capturedSeconds: finiteDouble(object["capturedSeconds"]),
            processingState: object["processingState"] as? String,
            comparisonAllowed: optionalBool(object["comparisonAllowed"]),
            contentSHA256: nonEmptyString(object["contentSHA256"]),
            topFeaturePath: topFeaturePath,
            segments: segments?.map {
                AliasSegmentIdentity(
                    id: $0.id,
                    featurePath: $0.featurePath,
                    mediaStartSeconds: $0.mediaStartSeconds,
                    capturedSeconds: $0.capturedSeconds
                )
            }
        )
    }
    return TrackInput(
        row: row,
        body: object,
        trackIDString: idString,
        trackID: trackID,
        topFeaturePath: topFeaturePath,
        capturedSeconds: finiteDouble(object["capturedSeconds"]),
        segments: segments,
        identity: identity
    )
}

private func collectFeaturePaths(_ track: TrackInput, includeAggregate: Bool) -> [String] {
    var result: [String] = []
    if includeAggregate, let top = track.topFeaturePath { result.append(top) }
    for segment in track.segments ?? [] {
        if let path = segment.featurePath { result.append(path) }
    }
    if track.segments == nil, let top = track.topFeaturePath { result.append(top) }
    return Array(Set(result)).sorted()
}

private func collectManifestPaths(_ track: TrackInput) -> [String] {
    guard track.segments?.count ?? 0 > 1, let path = track.topFeaturePath else { return [] }
    return [path]
}

private func trackAudioPaths(_ track: TrackInput) -> [String] {
    var result: [String] = []
    if let path = track.body["audioPath"] as? String, !path.isEmpty { result.append(path) }
    if let path = track.body["rawAudioPath"] as? String, !path.isEmpty { result.append(path) }
    for segment in track.segments ?? [] {
        if let path = segment.audioPath, !path.isEmpty { result.append(path) }
    }
    return Array(Set(result)).sorted()
}

private func resolve(path: String, source: URL) -> String {
    let url = URL(fileURLWithPath: path)
    if url.path.hasPrefix("/") { return url.standardizedFileURL.resolvingSymlinksInPath().path }
    return source.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath().path
}

private func canonicalOutputPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

private func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
}

private func finiteDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
    if let string = value as? String, let result = Double(string), result.isFinite { return result }
    return nil
}

private func optionalBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
}

private func encodeJSON(_ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
        throw CompactLibraryError.source("TrackEntry JSON 更新后不可序列化")
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func artifactMarker(at url: URL) -> String? {
    autoreleasepool {
        guard let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) else {
            return nil
        }
        guard let header = try? PropertyListDecoder().decode(CompactLibraryArtifactHeader.self, from: data as Data) else {
            return nil
        }
        return header.resonanceArtifact
    }
}

private func fileSize(_ url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber else { return nil }
    return size.int64Value
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try JSONEncoder.pretty.encode(value).write(to: url, options: .atomic)
}

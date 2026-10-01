import Foundation
import SQLite3
import CryptoKit
#if canImport(ResonanceCore)
import ResonanceCore
#endif

/// A combined recording owns its timeline, not another copy of every segment's
/// PSD. References are restricted to sibling artifacts in the Features folder.
struct SpectrumSegmentReference: Codable, Sendable, Equatable {
    let fileName: String
    let recordingID: UUID
    let mediaStartSeconds: Double
    let capturedSeconds: Double
}

private struct SpectrumSegmentManifest: Codable {
    let resonanceArtifact: String
    let metadata: SpectrumFeatures
    let segments: [SpectrumSegmentReference]
}

private struct SpectrumArtifactHeader: Decodable {
    let resonanceArtifact: String?
}

enum StoreError: LocalizedError {
    case database(String)
    var errorDescription: String? { if case .database(let message) = self { return "本地资料库：\(message)" }; return nil }
}

@MainActor
final class LocalStore {
    let directory: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Resonance", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        for name in ["Audio", "Features", "Sources", "Exports"] {
            try FileManager.default.createDirectory(at: self.directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        guard sqlite3_open_v2(self.directory.appendingPathComponent("library.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS documents (kind TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL, modified REAL NOT NULL, PRIMARY KEY(kind,id))")
    }

    deinit { sqlite3_close(db) }

    func load<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM documents WHERE kind=? ORDER BY modified DESC", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        var values: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            values.append(try JSONDecoder().decode(type, from: data))
        }
        return values
    }

    func save<T: Encodable>(_ value: T, kind: String, id: String) throws {
        let data = try JSONEncoder().encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO documents(kind,id,body,modified) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body, modified=excluded.modified", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func remove(kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM documents WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func featureURL(id: UUID) -> URL { directory.appendingPathComponent("Features/\(id.uuidString).plist.lzfse") }

    nonisolated static func writeArtifact<T: Encodable>(_ value: T, to url: URL) throws {
        // A batch can run as one long Swift task. Drain Foundation's temporary
        // plist/compression objects here instead of retaining each song's
        // buffers until that task eventually yields or finishes.
        try autoreleasepool {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let compressed = try (encoder.encode(value) as NSData).compressed(using: .lzfse)
            try (compressed as Data).write(to: url, options: .atomic)
        }
    }

    /// Compact encoding is explicit: unrelated artifacts and old verification
    /// fixtures retain their exact Float64 representation.
    nonisolated static func writeCompactSpectrum(_ value: SpectrumFeatures, to url: URL) throws {
        guard value.compactStorage != nil, value.frequencyCellEdgesHz != nil else {
            throw StoreError.database("精简频谱缺少频率区间或近似表示说明")
        }
        try CompactSpectrum.validate(value)
        try autoreleasepool {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            encoder.userInfo[.resonanceCompactSpectrum] = true
            let compressed = try (encoder.encode(value) as NSData).compressed(using: .lzfse)
            try (compressed as Data).write(to: url, options: .atomic)
        }
    }

    nonisolated static func readArtifact<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try autoreleasepool {
            let data = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse)
            let decoder = PropertyListDecoder()
            let header = type == SpectrumFeatures.self
                ? try decoder.decode(SpectrumArtifactHeader.self, from: data as Data) : nil
            if let marker = header?.resonanceArtifact {
                guard marker == "spectrum-segments-v1", type == SpectrumFeatures.self else {
                    throw StoreError.database("不支持的频谱引用格式：\(marker)")
                }
                let manifest = try decoder.decode(SpectrumSegmentManifest.self, from: data as Data)
                guard let result = try readSpectrumManifest(manifest, at: url) as? T else {
                    throw StoreError.database("频谱引用类型不匹配")
                }
                return result
            }
            let decoded = try decoder.decode(type, from: data as Data)
            if let feature = decoded as? SpectrumFeatures, feature.compactStorage != nil {
                try CompactSpectrum.validate(feature)
            }
            return decoded
        }
    }

    nonisolated static func writeSpectrumManifest(
        metadata: SpectrumFeatures,
        segments: [SpectrumSegmentReference],
        to url: URL
    ) throws {
        guard !segments.isEmpty, segments.allSatisfy(validSpectrumReference) else {
            throw StoreError.database("频谱引用缺少有效片段或媒体起点")
        }
        if metadata.compactStorage != nil { try CompactSpectrum.validate(metadata) }
        // Copy just the small metadata. The manifest never serializes the
        // already-merged frame array.
        let empty = spectrumReplacingFrames(metadata, frames: [])
        try writeArtifact(SpectrumSegmentManifest(
            resonanceArtifact: "spectrum-segments-v1", metadata: empty, segments: segments
        ), to: url)
    }

    nonisolated private static func validSpectrumReference(_ part: SpectrumSegmentReference) -> Bool {
        !part.fileName.isEmpty && part.fileName != "." && part.fileName != ".."
            && !part.fileName.contains("/") && !part.fileName.contains("\\")
            && part.mediaStartSeconds.isFinite && part.mediaStartSeconds >= 0
            && part.capturedSeconds.isFinite && part.capturedSeconds > 0
    }

    nonisolated private static func readSpectrumManifest(
        _ manifest: SpectrumSegmentManifest, at url: URL
    ) throws -> SpectrumFeatures {
        guard manifest.metadata.frames.isEmpty, !manifest.segments.isEmpty,
              manifest.segments.allSatisfy(validSpectrumReference) else {
            throw StoreError.database("频谱引用元数据无效")
        }
        let metadata = manifest.metadata
        var frames: [SpectrumFrame] = []
        var prior: [(Double, Double)] = []
        for part in manifest.segments.sorted(by: { $0.mediaStartSeconds < $1.mediaStartSeconds }) {
            try Task.checkCancellation()
            let childURL = url.deletingLastPathComponent().appendingPathComponent(part.fileName)
            let child: SpectrumFeatures = try autoreleasepool {
                let bytes = try (Data(contentsOf: childURL) as NSData).decompressed(using: .lzfse) as Data
                let decoder = PropertyListDecoder()
                // A segment must be a leaf. This also rejects cycles and
                // nested references instead of recursively decoding them.
                guard try decoder.decode(SpectrumArtifactHeader.self, from: bytes).resonanceArtifact == nil else {
                    throw StoreError.database("合并频谱只能引用独立片段")
                }
                return try decoder.decode(SpectrumFeatures.self, from: bytes)
            }
            guard child.recordingID == part.recordingID,
                  child.sampleRate == metadata.sampleRate,
                  child.channelCount == metadata.channelCount,
                  child.frequencyBinsHz == metadata.frequencyBinsHz,
                  child.frequencyCellEdgesHz == metadata.frequencyCellEdgesHz,
                  child.compactStorage == metadata.compactStorage,
                  child.format == metadata.format,
                  child.parameters == metadata.parameters,
                  child.analyzerVersion == metadata.analyzerVersion else {
                throw StoreError.database("频谱引用的身份或分析参数已变化")
            }
            if child.compactStorage != nil { try CompactSpectrum.validate(child) }
            let tolerance = max(1, Double(child.parameters.hopLength)) / child.sampleRate
            guard child.sampleRate.isFinite, child.sampleRate > 0,
                  child.durationSeconds.isFinite, child.durationSeconds > 0,
                  abs(part.capturedSeconds - child.durationSeconds) <= tolerance else {
                throw StoreError.database("频谱引用时长与片段实际时长不一致")
            }
            for frame in child.frames {
                let start = part.mediaStartSeconds + frame.startTimeSeconds
                let end = start + Double(frame.sampleCount) / child.sampleRate
                let center = (start + end) / 2
                guard frame.startTimeSeconds >= 0, start.isFinite, end.isFinite, end > start,
                      end <= part.mediaStartSeconds + part.capturedSeconds + tolerance else {
                    throw StoreError.database("频谱引用包含无效帧时间")
                }
                if prior.contains(where: { center > $0.0 && center < $0.1 }) { continue }
                frames.append(SpectrumFrame(startTimeSeconds: start, sampleCount: frame.sampleCount,
                    powerSpectralDensityByChannel: frame.powerSpectralDensityByChannel))
            }
            prior.append((part.mediaStartSeconds, part.mediaStartSeconds + part.capturedSeconds))
        }
        guard !frames.isEmpty else { throw StoreError.database("频谱引用没有有效帧") }
        frames.sort { $0.startTimeSeconds < $1.startTimeSeconds }
        return spectrumReplacingFrames(metadata, frames: frames)
    }

    nonisolated private static func spectrumReplacingFrames(
        _ source: SpectrumFeatures, frames: [SpectrumFrame]
    ) -> SpectrumFeatures {
        SpectrumFeatures(recordingID: source.recordingID, sampleRate: source.sampleRate,
            channelCount: source.channelCount, frequencyBinsHz: source.frequencyBinsHz,
            frames: frames, durationSeconds: source.durationSeconds, coverage: source.coverage,
            validMinHz: source.validMinHz, validMaxHz: source.validMaxHz,
            frequencyValidity: source.frequencyValidity, format: source.format,
            parameters: source.parameters, analyzerVersion: source.analyzerVersion,
            frequencyCellEdgesHz: source.frequencyCellEdgesHz, compactStorage: source.compactStorage)
    }

    nonisolated static func audioDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: {
            guard let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty else { return false }
            digest.update(data: bytes)
            return true
        }) {}
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> StoreError {
        .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开资料库")
    }
}

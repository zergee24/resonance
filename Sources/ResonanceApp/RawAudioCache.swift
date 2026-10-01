import Foundation
import ResonanceCore

/// A conservative, post-analysis raw-audio cache. The cache only removes CAF
/// files that are still referenced by the current library and whose durable
/// feature artifacts were read back successfully.
struct RawAudioCachePlan: Sendable {
    struct Candidate: Sendable, Equatable {
        let path: String
        let byteCount: Int64
        let modifiedAt: Date
        let artifacts: [ArtifactFingerprint]
    }

    let snapshotToken: String
    let directoryPath: String
    let targetBytes: Int64
    let totalBytes: Int64
    let candidates: [Candidate]
}

struct ArtifactFingerprint: Sendable, Equatable {
    let path: String
    let byteCount: Int64
    let modifiedAt: Date
}

struct RawAudioCacheResult: Sendable, Equatable {
    let deletedFiles: Int
    let deletedBytes: Int64
}

enum RawAudioCacheError: LocalizedError {
    case invalidDirectory

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            return "原始音频缓存目录不可安全确认。"
        }
    }
}

enum RawAudioCache {
    static let defaultTargetBytes: Int64 = 2_000_000_000

    struct SegmentSnapshot: Sendable, Equatable {
        let id: UUID
        let audioPath: String
        let featurePath: String?
    }

    struct TrackSnapshot: Sendable, Equatable {
        let id: UUID
        let error: String?
        let processingState: String
        let aggregateFeaturePath: String?
        let rawAudioPath: String?
        let segments: [SegmentSnapshot]
    }

    struct LibrarySnapshot: Sendable, Equatable {
        let tracks: [TrackSnapshot]
        let pendingTrackIDs: Set<UUID>
        let token: String
    }

    static func snapshot(
        tracks: [TrackEntry],
        pendingTrackIDs: Set<UUID>
    ) -> LibrarySnapshot {
        let values = tracks.map { track in
            TrackSnapshot(
                id: track.id,
                error: track.error,
                processingState: track.processingState,
                aggregateFeaturePath: track.featurePath,
                rawAudioPath: track.rawAudioPath,
                segments: track.analysisSegments.map {
                    SegmentSnapshot(id: $0.id, audioPath: $0.audioPath, featurePath: $0.featurePath)
                }
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let token = makeToken(tracks: values, pendingTrackIDs: pendingTrackIDs)
        return LibrarySnapshot(tracks: values, pendingTrackIDs: pendingTrackIDs, token: token)
    }

    static func makePlan(
        directory: URL,
        snapshot: LibrarySnapshot,
        targetBytes: Int64 = defaultTargetBytes
    ) throws -> RawAudioCachePlan {
        guard targetBytes >= 0 else { throw RawAudioCacheError.invalidDirectory }
        let audioRoot = try secureAudioDirectory(in: directory)
        let files = try enumerateCAF(in: audioRoot)
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
        guard totalBytes > targetBytes else {
            return RawAudioCachePlan(
                snapshotToken: snapshot.token,
                directoryPath: directory.standardizedFileURL.path,
                targetBytes: targetBytes,
                totalBytes: totalBytes,
                candidates: []
            )
        }

        let references = referenceMap(snapshot: snapshot)
        let sorted = files.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return $0.path < $1.path
        }
        var remaining = totalBytes
        var candidates: [RawAudioCachePlan.Candidate] = []
        var aggregateValidation: [String: Bool] = [:]
        var leafValidation: [String: Bool] = [:]
        for file in sorted where remaining > targetBytes {
            guard let refs = references[file.path], !refs.isEmpty else { continue }
            var allSafe = true
            for reference in refs {
                if !referenceIsSafe(
                    reference,
                    snapshot: snapshot,
                    directory: directory,
                    aggregateValidation: &aggregateValidation,
                    leafValidation: &leafValidation
                ) {
                    allSafe = false
                    break
                }
            }
            guard allSafe else { continue }
            var artifacts: [ArtifactFingerprint] = []
            var artifactPaths = Set<String>()
            for reference in refs {
                guard let track = snapshot.tracks.first(where: { $0.id == reference.trackID }),
                      let aggregatePath = track.aggregateFeaturePath,
                      let featurePath = reference.featurePath else {
                    allSafe = false
                    break
                }
                for path in [aggregatePath, featurePath] {
                    let canonical = canonicalPath(path)
                    guard artifactPaths.insert(canonical).inserted else { continue }
                    guard let fingerprint = try? artifactFingerprint(URL(fileURLWithPath: canonical)) else {
                        allSafe = false
                        break
                    }
                    artifacts.append(fingerprint)
                }
                if !allSafe { break }
            }
            guard allSafe else { continue }
            candidates.append(.init(path: file.path, byteCount: file.byteCount, modifiedAt: file.modifiedAt, artifacts: artifacts))
            remaining -= file.byteCount
        }

        return RawAudioCachePlan(
            snapshotToken: snapshot.token,
            directoryPath: directory.standardizedFileURL.path,
            targetBytes: targetBytes,
            totalBytes: totalBytes,
            candidates: candidates
        )
    }

    static func apply(
        _ plan: RawAudioCachePlan,
        directory: URL,
        snapshot: LibrarySnapshot
    ) -> RawAudioCacheResult {
        guard snapshot.token == plan.snapshotToken,
              directory.standardizedFileURL.path == plan.directoryPath,
              let audioRoot = try? secureAudioDirectory(in: directory) else {
            return RawAudioCacheResult(deletedFiles: 0, deletedBytes: 0)
        }

        var deletedFiles = 0
        var deletedBytes: Int64 = 0
        for candidate in plan.candidates {
            guard let current = try? fileMetadata(URL(fileURLWithPath: candidate.path)),
                  current.byteCount == candidate.byteCount,
                  current.modifiedAt == candidate.modifiedAt,
                  isSafeCAF(URL(fileURLWithPath: candidate.path), audioRoot: audioRoot),
                  candidate.artifacts.allSatisfy({ fingerprint in
                      guard let current = try? artifactFingerprint(URL(fileURLWithPath: fingerprint.path)) else { return false }
                      return current == fingerprint && isSafeFeatureURL(URL(fileURLWithPath: fingerprint.path), directory: directory)
                  }) else {
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: candidate.path)
                deletedFiles += 1
                deletedBytes += candidate.byteCount
            } catch {
                continue
            }
        }
        return RawAudioCacheResult(deletedFiles: deletedFiles, deletedBytes: deletedBytes)
    }

    private struct CAFFile {
        let path: String
        let byteCount: Int64
        let modifiedAt: Date
    }

    private struct Reference {
        let trackID: UUID
        let segmentID: UUID?
        let featurePath: String?
        let trackHasError: Bool
    }

    private static func referenceMap(snapshot: LibrarySnapshot) -> [String: [Reference]] {
        var result: [String: [Reference]] = [:]
        for track in snapshot.tracks {
            let hasError = snapshot.pendingTrackIDs.contains(track.id) ||
                track.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                track.processingState.contains("失败") || track.processingState.contains("不可用")
            for segment in track.segments {
                let reference = Reference(
                    trackID: track.id,
                    segmentID: segment.id,
                    featurePath: segment.featurePath,
                    trackHasError: hasError
                )
                result[canonicalPath(segment.audioPath), default: []].append(reference)
            }
            if let rawAudioPath = track.rawAudioPath, !rawAudioPath.isEmpty {
                let reference = Reference(
                    trackID: track.id,
                    segmentID: nil,
                    featurePath: nil,
                    trackHasError: true
                )
                result[canonicalPath(rawAudioPath), default: []].append(reference)
            }
        }
        return result
    }

    private static func referenceIsSafe(
        _ reference: Reference,
        snapshot: LibrarySnapshot,
        directory: URL,
        aggregateValidation: inout [String: Bool],
        leafValidation: inout [String: Bool]
    ) -> Bool {
        guard !reference.trackHasError,
              let track = snapshot.tracks.first(where: { $0.id == reference.trackID }),
              let segmentID = reference.segmentID,
              let featurePath = reference.featurePath,
              !featurePath.isEmpty else { return false }
        let aggregatePath = track.aggregateFeaturePath
        let aggregateExpectedID: UUID
        if track.segments.count == 1,
           let singleFeaturePath = track.segments[0].featurePath,
           let aggregatePath,
           canonicalPath(singleFeaturePath) == canonicalPath(aggregatePath) {
            aggregateExpectedID = track.segments[0].id
        } else {
            aggregateExpectedID = track.id
        }
        guard let aggregatePath, !aggregatePath.isEmpty,
              validateFeature(
                  path: aggregatePath,
                  expectedID: aggregateExpectedID,
                  directory: directory,
                  cache: &aggregateValidation
              ) else { return false }
        return validateFeature(
            path: featurePath,
            expectedID: segmentID,
            directory: directory,
            cache: &leafValidation
        )
    }

    private static func validateFeature(
        path: String,
        expectedID: UUID,
        directory: URL,
        cache: inout [String: Bool]
    ) -> Bool {
        let normalized = standardizedPath(path)
        let cacheKey = "\(normalized)|\(expectedID.uuidString)"
        if let cached = cache[cacheKey] { return cached }
        let featuresRoot = directory.appendingPathComponent("Features", isDirectory: true).standardizedFileURL
        let url = URL(fileURLWithPath: normalized)
        let resolvedRoot = featuresRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/"),
              isRegularNonSymlink(url) else { return false }
        let valid: Bool = autoreleasepool {
            guard let feature = try? LocalStore.readArtifact(SpectrumFeatures.self, from: url) else { return false }
            return feature.recordingID == expectedID && !feature.frames.isEmpty
        }
        cache[cacheKey] = valid
        return valid
    }

    private static func enumerateCAF(in root: URL) throws -> [CAFFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var result: [CAFFile] = []
        for case let url as URL in enumerator {
            guard let metadata = try? fileMetadata(url),
                  url.pathExtension.caseInsensitiveCompare("caf") == .orderedSame,
                  isSafeCAF(url, audioRoot: root) else { continue }
            result.append(metadata)
        }
        return result
    }

    private static func fileMetadata(_ url: URL) throws -> CAFFile {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate,
              modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RawAudioCacheError.invalidDirectory
        }
        return CAFFile(path: canonicalPath(url.path), byteCount: Int64(size), modifiedAt: modifiedAt)
    }

    private static func artifactFingerprint(_ url: URL) throws -> ArtifactFingerprint {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate,
              modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RawAudioCacheError.invalidDirectory
        }
        return ArtifactFingerprint(path: canonicalPath(url.path), byteCount: Int64(size), modifiedAt: modifiedAt)
    }

    private static func secureAudioDirectory(in directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("Audio", isDirectory: true).standardizedFileURL
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw RawAudioCacheError.invalidDirectory
        }
        return canonical
    }

    private static func isSafeCAF(_ url: URL, audioRoot: URL) -> Bool {
        let normalized = url.standardizedFileURL
        let resolvedRoot = audioRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = normalized.resolvingSymlinksInPath().standardizedFileURL
        guard normalized.path.hasPrefix(audioRoot.path + "/"),
              resolvedURL.path.hasPrefix(resolvedRoot.path + "/"),
              normalized.pathExtension.caseInsensitiveCompare("caf") == .orderedSame,
              isRegularNonSymlink(normalized) else { return false }
        return true
    }

    private static func isRegularNonSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isSafeFeatureURL(_ url: URL, directory: URL) -> Bool {
        let root = directory.appendingPathComponent("Features", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path.hasPrefix(root.path + "/") && isRegularNonSymlink(url)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func makeToken(tracks: [TrackSnapshot], pendingTrackIDs: Set<UUID>) -> String {
        let trackPart = tracks.map { track in
            let segments = track.segments.map { "\($0.id.uuidString)=\($0.audioPath)=\($0.featurePath ?? "")" }.joined(separator: ";")
            return "\(track.id.uuidString)|\(track.error ?? "")|\(track.processingState)|\(track.aggregateFeaturePath ?? "")|\(track.rawAudioPath ?? "")|\(segments)"
        }.joined(separator: "||")
        let pendingPart = pendingTrackIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "\(trackPart)||pending=\(pendingPart)"
    }
}

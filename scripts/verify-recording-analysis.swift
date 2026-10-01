import AVFoundation
import Foundation
import ResonanceCore

// State-only host for the production RecordingAnalysis extension. No browser,
// audio device, player polling, user defaults, or real library is instantiated.
struct PlayerSnapshot {
    var trackID: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var sourceBundleIdentifier: String?
    var systemItemIdentifier: String?
    var candidateKey: String = ""
}
struct InactivePlayer { var snapshot: PlayerSnapshot? }
final class CaptureStub { var isRecording = false }

@MainActor
final class AppModel {
    var database: LocalStore?
    var tracks: [TrackEntry] = []
    var isShuttingDown = false
    var queuedAnalysisKeys = Set<String>()
    var analysisTask: Task<Void, Never>?
    var analysisRevision: UUID?
    var busy = false
    var status = ""
    var selectedTrackID: UUID?
    var isFollowPlaying = false
    var player = InactivePlayer()
    var capture = CaptureStub()
    var captureTrackID: UUID?
    var captureStartTask: Task<Void, Never>?
    var rawAudioCacheTask: Task<Void, Never>?
    var automaticListeningStatus = ""
    var errorMessage: String?
    var saveCount = 0
    var recomputeCount = 0

    init(directory: URL) throws { database = try LocalStore(directory: directory) }
    func saveTrack(_ track: TrackEntry) throws {
        guard let database else { throw CheckFailure(message: "missing temporary store") }
        try database.save(track, kind: "tracks", id: track.id.uuidString)
        if let index = tracks.firstIndex(where: { $0.id == track.id }) { tracks[index] = track }
        else { tracks.append(track) }
        saveCount += 1
    }
    func report(_ error: Error) { errorMessage = error.localizedDescription }
    func recompute() { recomputeCount += 1 }
}

struct CheckFailure: Error { let message: String }

@main
struct RecordingAnalysisHarness {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resonance-analysis-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await shortThenValid(directory)
        try await allShortThenAppend(directory)
        try await mixedLegacyCompaction(directory)
        try await featureOnlyManifestRecovery(directory)
        try await singleAndLegacy(directory)
        try await badInputs(directory)
        print("recording analysis queue harness: PASS")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    static func pcm(frames: Int, directory: URL, start: Double) throws -> RecordingSegment {
        let url = directory.appendingPathComponent("\(UUID()).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            if frames > 0 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                buffer.frameLength = AVAudioFrameCount(frames)
                for index in 0..<frames {
                    buffer.floatChannelData![0][index] = Float(0.2 * sin(Double(index) * 2 * .pi * 440 / 48_000))
                }
                try file.write(from: buffer)
            }
        }
        return RecordingSegment(audioPath: url.path, mediaStartSeconds: start,
                                capturedSeconds: Double(frames) / 48_000, sampleRate: 48_000, channels: 1)
    }

    @MainActor
    static func run(_ model: AppModel, _ track: TrackEntry) async throws -> TrackEntry {
        try model.saveTrack(track)
        model.enqueueAnalysis(track: track, coverage: try Coverage(kind: .partial),
                              automatic: false, selectOnCompletion: false, recomputeOnCompletion: false)
        // Follow any replacement revision queued by the production code.
        for _ in 0..<10 {
            let revision = model.analysisRevision
            await model.analysisTask?.value
            if revision == model.analysisRevision { break }
        }
        try check(!model.busy && model.queuedAnalysisKeys.isEmpty, "queue did not drain")
        guard let result = model.tracks.first(where: { $0.id == track.id }) else {
            throw CheckFailure(message: "row disappeared")
        }
        return result
    }

    @MainActor
    static func shortThenValid(_ directory: URL) async throws {
        let model = try AppModel(directory: directory.appendingPathComponent("mixed-store"))
        var short = try pcm(frames: 7_168, directory: directory, start: 0)
        short.contentSHA256 = try LocalStore.audioDigest(URL(fileURLWithPath: short.audioPath))
        let valid = try pcm(frames: 24_000, directory: directory, start: 0.14933333333333335)
        let before = try [short, valid].map { try LocalStore.audioDigest(URL(fileURLWithPath: $0.audioPath)) }
        var track = TrackEntry(title: "short prefix then valid", artist: "fixture", duration: 0.6493333333333333)
        track.recordingSegments = [short, valid]
        track.error = "Audio is shorter than one analysis frame"
        let result = try await run(model, track)
        try check(result.error == nil && result.analyzed, "short prefix aborted the valid segment")
        try check(!result.isFull, "short prefix was hidden by full-coverage tolerance")
        try check(result.analysisSegments.count == 2, "short raw segment was removed")
        try check(result.analysisSegments[0].featurePath == nil, "short segment received fabricated spectrum")
        try check(result.analysisSegments[0].contentSHA256 == short.contentSHA256, "short PCM digest was discarded")
        try check(result.analysisSegments[1].featurePath != nil, "valid segment not attached")
        let feature = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: result.featurePath!))
        try check(feature.coverage.kind == .partial && !feature.frames.isEmpty, "aggregate lacks real partial frames")
        try check(feature.coverage.intervals.count == 1, "deferred audio leaked into feature coverage")
        try check(abs(feature.coverage.intervals[0].startSeconds - valid.mediaStartSeconds!) < 1e-9, "valid media offset lost")
        try check(abs(feature.frames[0].startTimeSeconds - valid.mediaStartSeconds!) < 1e-9, "spectrum frame offset lost")
        try check(abs(feature.coverage.recordedDurationSeconds! - valid.capturedSeconds) < 1e-9, "short duration counted as analyzed")
        try check(result.analysisNotes?.contains(where: { $0.contains("短于分析窗") }) == true, "short omission not explained")
        let after = try [short, valid].map { try LocalStore.audioDigest(URL(fileURLWithPath: $0.audioPath)) }
        try check(before == after, "source PCM changed")
        try checkManifest(URL(fileURLWithPath: result.featurePath!), segmentCount: 1)
        try check(!model.restorePendingAnalyses(), "settled mixed row was queued again")
        let stored = try model.database!.load(TrackEntry.self, kind: "tracks")
        try check(stored.first?.featurePath == result.featurePath && stored.first?.error == nil, "persisted result differs")
        let segmentFeature = try LocalStore.readArtifact(
            SpectrumFeatures.self, from: URL(fileURLWithPath: result.analysisSegments[1].featurePath!)
        )
        try matchRecoveredFeature(feature, validSegment: segmentFeature)
        print("PASS production queue: short prefix + valid, PCM preservation, real partial coverage, no retry")
    }

    static func matchRecoveredFeature(_ recovered: SpectrumFeatures, validSegment: SpectrumFeatures) throws {
        let frequencies = [20.0, 100, 500, 1_000, 10_000, 24_000]
        let levels = [5.0, 5, 0, -5, 3, 3]
        let measured = try Curve(
            name: "synthetic measured", points: zip(frequencies, levels).map {
                try CurvePoint(frequencyHz: $0.0, decibels: $0.1)
            }, source: "fixture", measurementSystem: "fixture"
        )
        let reference = try Curve(
            name: "synthetic flat", points: frequencies.map { try CurvePoint(frequencyHz: $0, decibels: 0) },
            source: "fixture", measurementSystem: "fixture", isReference: true
        )
        // Recovered fixture is mono. A measured but unused right channel must
        // not erase its valid frequency range in either matching algorithm.
        let unusedRight = try Curve(
            name: "unused right", points: [30_000.0, 40_000].map { try CurvePoint(frequencyHz: $0, decibels: 8) },
            source: "fixture", measurementSystem: "fixture"
        )
        let headphone = Headphone(name: "fixture", owned: true, curve: measured, rightCurve: unusedRight)
        let classic = Matcher().match(features: recovered, headphone: headphone, reference: reference)
        let classicSegment = Matcher().match(features: validSegment, headphone: headphone, reference: reference)
        try check(classic.status == .partial && classic.completeOrPartial == .partial,
                  "classic matcher lost partial coverage after recovery")
        guard let d = classic.d, let segmentD = classicSegment.d, let c = classic.c, let segmentC = classicSegment.c else {
            throw CheckFailure(message: "recovered audio did not enter classic matching")
        }
        try check(d.isFinite && c.isFinite && abs(d - segmentD) < 1e-10 && abs(c - segmentC) < 1e-10,
                  "deferred short audio or media offset changed classic scores")

        let references = [reference, measured]
        let personal = PersonalMatcher().match(features: recovered, headphone: headphone, references: references)
        let personalSegment = PersonalMatcher().match(features: validSegment, headphone: headphone, references: references)
        try check(personal.bestReferenceID == measured.id && personal.bestReferenceID == personalSegment.bestReferenceID,
                  "recovered audio selected the wrong reference")
        try check(personal.matches.count == references.count && personal.matches.allSatisfy { $0.status == .partial },
                  "personal matcher lost partial coverage after recovery")
        for result in personal.matches {
            guard let score = result.overallDeviationDB,
                  let original = personalSegment.matches.first(where: { $0.referenceID == result.referenceID })?.overallDeviationDB else {
                throw CheckFailure(message: "recovered audio did not enter personal matching")
            }
            try check(score.isFinite && abs(score - original) < 1e-10, "deferred short audio changed personal scores")
        }
        try check(!personal.sensitivityDiagnostics.isEmpty, "recovered audio lost weighting diagnostics")
        print("PASS recovery -> both matchers: finite scores, partial retained, valid-segment scores and reference unchanged")
    }

    @MainActor
    static func allShortThenAppend(_ directory: URL) async throws {
        let store = directory.appendingPathComponent("waiting-store")
        let model = try AppModel(directory: store)
        let short = try pcm(frames: 7_168, directory: directory, start: 0)
        var track = TrackEntry(title: "waiting then resume", artist: "fixture", duration: 2)
        track.recordingSegments = [short]
        let waiting = try await run(model, track)
        try check(waiting.error == nil && !waiting.analyzed && !waiting.isFull, "all-short row was failed or analyzed")
        try check(waiting.processingState.contains("等待后续录音"), "all-short row has no waiting state")
        try check(try FileManager.default.contentsOfDirectory(atPath: store.appendingPathComponent("Features").path).isEmpty,
                  "all-short queue wrote fake feature")
        let restored = try AppModel(directory: store)
        restored.tracks = try restored.database!.load(TrackEntry.self, kind: "tracks")
        try check(!restored.restorePendingAnalyses(), "all-short row retried after reload")
        let valid = try pcm(frames: 24_000, directory: directory, start: 1)
        var resumed = restored.tracks[0]
        RecordingContinuation.append(valid, to: &resumed)
        let result = try await run(restored, resumed)
        try check(result.error == nil && result.analyzed && result.analysisSegments.count == 2, "appended valid segment did not recover")
        try check(!restored.restorePendingAnalyses(), "recovered row kept retrying")
        let segmentFeatureURL = URL(fileURLWithPath: result.analysisSegments[1].featurePath!)
        let savedFeature = try Data(contentsOf: segmentFeatureURL)
        let savedDate = try segmentFeatureURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // Lose only the aggregate, then use normal recovery: existing segment
        // artifact must be reused, not decoded and rewritten.
        try FileManager.default.removeItem(atPath: result.featurePath!)
        try check(restored.restorePendingAnalyses(), "missing aggregate did not recover")
        await restored.analysisTask?.value
        try check(restored.tracks[0].error == nil && restored.tracks[0].analyzed, "aggregate recovery failed")
        try check(try Data(contentsOf: segmentFeatureURL) == savedFeature, "existing segment feature changed")
        try check(try segmentFeatureURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == savedDate,
                  "existing segment feature was rewritten")
        print("PASS production recovery: all-short waits across reload, new valid tail resumes, saved feature reused")
    }

    @MainActor
    static func mixedLegacyCompaction(_ directory: URL) async throws {
        let model = try AppModel(directory: directory.appendingPathComponent("mixed-legacy-store"))
        let legacyRaw = try pcm(frames: 24_000, directory: directory, start: 0)
        let compactRaw = try pcm(frames: 24_000, directory: directory, start: 1)
        let legacyID = legacyRaw.id
        let legacyCoverage = try Coverage(
            kind: .partial,
            recordedDurationSeconds: legacyRaw.capturedSeconds,
            intervals: [try TimeRange(startSeconds: 0, endSeconds: legacyRaw.capturedSeconds)]
        )
        let legacyFeature = try SpectrumAnalyzer().analyze(
            fileURL: URL(fileURLWithPath: legacyRaw.audioPath),
            coverage: legacyCoverage,
            recordingID: legacyID
        )
        let legacyURL = model.database!.directory.appendingPathComponent(
            "Features/\(legacyID.uuidString)-legacy.plist.lzfse"
        )
        try LocalStore.writeArtifact(legacyFeature, to: legacyURL)
        let legacyBytes = try Data(contentsOf: legacyURL)
        var legacySegment = legacyRaw
        legacySegment.featurePath = legacyURL.path
        var track = TrackEntry(title: "legacy plus compact", artist: "fixture", duration: 2)
        track.recordingSegments = [legacySegment, compactRaw]
        let result = try await run(model, track)
        guard let aggregate = result.featurePath,
              let convertedPath = result.analysisSegments[0].featurePath else {
            throw CheckFailure(message: "mixed legacy/compact row lost feature paths")
        }
        try check(convertedPath != legacyURL.path, "legacy mixed segment was rewritten in place")
        try check(try Data(contentsOf: legacyURL) == legacyBytes, "legacy feature artifact was mutated")
        let converted = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: convertedPath))
        try check(converted.compactStorage != nil && converted.frequencyCellEdgesHz != nil,
                  "legacy mixed segment did not receive compact sibling artifact")
        try checkManifest(URL(fileURLWithPath: aggregate), segmentCount: 2)
        print("PASS mixed legacy/compact: legacy leaf compacted to a sibling before manifest, original artifact preserved")
    }

    @MainActor
    static func featureOnlyManifestRecovery(_ directory: URL) async throws {
        let store = directory.appendingPathComponent("feature-only-store")
        let model = try AppModel(directory: store)
        let first = try pcm(frames: 24_000, directory: directory, start: 0)
        let second = try pcm(frames: 24_000, directory: directory, start: 1)
        var track = TrackEntry(title: "feature-only recovery", artist: "fixture", duration: 2)
        track.recordingSegments = [first, second]
        let initial = try await run(model, track)
        guard let aggregatePath = initial.featurePath,
              let firstFeaturePath = initial.analysisSegments[0].featurePath,
              let secondFeaturePath = initial.analysisSegments[1].featurePath else {
            throw CheckFailure(message: "multi-segment manifest did not attach all artifacts")
        }
        let aggregateURL = URL(fileURLWithPath: aggregatePath)
        try checkManifest(aggregateURL, segmentCount: 2)
        let malformedDurationURL = store.appendingPathComponent("Features/\(initial.id.uuidString)-bad-duration.plist.lzfse")
        try rewriteManifestDuration(
            from: aggregateURL,
            to: malformedDurationURL,
            capturedSeconds: first.capturedSeconds * 2
        )
        var rejectedMalformedDuration = false
        do {
            _ = try LocalStore.readArtifact(SpectrumFeatures.self, from: malformedDurationURL)
        } catch {
            rejectedMalformedDuration = true
        }
        try check(rejectedMalformedDuration, "manifest accepted a leaf duration twice the PCM duration")

        let smallDeltaURL = store.appendingPathComponent("Features/\(initial.id.uuidString)-small-duration-delta.plist.lzfse")
        let leafFeature = try LocalStore.readArtifact(
            SpectrumFeatures.self,
            from: URL(fileURLWithPath: initial.analysisSegments[0].featurePath!)
        )
        let halfHop = 0.25 * Double(leafFeature.parameters.hopLength) / leafFeature.sampleRate
        try rewriteManifestDuration(
            from: aggregateURL,
            to: smallDeltaURL,
            capturedSeconds: first.capturedSeconds + halfHop
        )
        let smallDeltaFeature = try LocalStore.readArtifact(SpectrumFeatures.self, from: smallDeltaURL)
        try check(!smallDeltaFeature.frames.isEmpty, "manifest rejected a duration delta smaller than half a hop")
        let firstFeatureURL = URL(fileURLWithPath: firstFeaturePath)
        let secondFeatureURL = URL(fileURLWithPath: secondFeaturePath)
        let firstBytes = try Data(contentsOf: firstFeatureURL)
        let secondBytes = try Data(contentsOf: secondFeatureURL)
        let firstDate = try firstFeatureURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let secondDate = try secondFeatureURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        // Simulate the future finite raw-audio cache only for these temporary
        // fixtures. Segment artifacts and the metadata row remain available.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: first.audioPath))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: second.audioPath))
        try FileManager.default.removeItem(at: aggregateURL)
        try check(model.restorePendingAnalyses(), "feature-only row did not recover missing aggregate")
        await model.analysisTask?.value
        guard let recovered = model.tracks.first(where: { $0.id == initial.id }),
              let recoveredAggregate = recovered.featurePath else {
            throw CheckFailure(message: "feature-only aggregate recovery lost the track")
        }
        try check(recovered.error == nil && recovered.analyzed, "feature-only aggregate recovery failed")
        try checkManifest(URL(fileURLWithPath: recoveredAggregate), segmentCount: 2)
        try check(try Data(contentsOf: firstFeatureURL) == firstBytes, "first segment feature was rewritten during no-PCM recovery")
        try check(try Data(contentsOf: secondFeatureURL) == secondBytes, "second segment feature was rewritten during no-PCM recovery")
        try check(try firstFeatureURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == firstDate,
                  "first segment feature timestamp changed during no-PCM recovery")
        try check(try secondFeatureURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == secondDate,
                  "second segment feature timestamp changed during no-PCM recovery")
        let recoveredFeature = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: recoveredAggregate))
        try checkReadableMatch(recoveredFeature)

        // Append a new tail while the earlier PCM is gone. Continuation uses
        // media coverage, and analysis must reuse the two leaf artifacts.
        let tail = try pcm(frames: 24_000, directory: directory, start: 2)
        var resumed = recovered
        RecordingContinuation.append(tail, to: &resumed)
        let continued = try await run(model, resumed)
        guard let continuedAggregate = continued.featurePath else {
            throw CheckFailure(message: "no-PCM continuation lost aggregate manifest")
        }
        try check(continued.error == nil && continued.analyzed && continued.analysisSegments.count == 3,
                  "no-PCM continuation did not append the valid tail")
        try checkManifest(URL(fileURLWithPath: continuedAggregate), segmentCount: 3)
        try check(try Data(contentsOf: firstFeatureURL) == firstBytes, "first leaf changed after no-PCM continuation")
        try check(try Data(contentsOf: secondFeatureURL) == secondBytes, "second leaf changed after no-PCM continuation")
        try FileManager.default.removeItem(at: secondFeatureURL)
        var missingLeafFailed = false
        do {
            _ = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: continuedAggregate))
        } catch {
            missingLeafFailed = true
        }
        try check(missingLeafFailed, "manifest with a missing leaf was silently accepted")
        print("PASS feature-only recovery: manifest has no PSD frames, missing aggregate rebuilt without PCM, matching readback and tail continuation reused leaves")
    }

    static func checkManifest(_ url: URL, segmentCount: Int) throws {
        let bytes = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try PropertyListSerialization.propertyList(from: bytes, options: [], format: &format) as? [String: Any] else {
            throw CheckFailure(message: "aggregate artifact is not a property-list manifest")
        }
        try check(root["resonanceArtifact"] as? String == "spectrum-segments-v1", "aggregate artifact was written as a duplicated PSD")
        guard let metadata = root["metadata"] as? [String: Any],
              let frames = metadata["frames"] as? [Any],
              let segments = root["segments"] as? [Any] else {
            throw CheckFailure(message: "spectrum manifest metadata or segment references are missing")
        }
        try check(frames.isEmpty, "spectrum manifest still contains aggregate PSD frames")
        try check(segments.count == segmentCount, "spectrum manifest segment count changed")
    }

    static func rewriteManifestDuration(from source: URL, to destination: URL, capturedSeconds: Double) throws {
        let compressed = try Data(contentsOf: source)
        let bytes = try (compressed as NSData).decompressed(using: .lzfse) as Data
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var root = try PropertyListSerialization.propertyList(from: bytes, options: [], format: &format) as? [String: Any],
              var segments = root["segments"] as? [[String: Any]],
              !segments.isEmpty else {
            throw CheckFailure(message: "could not decode manifest fixture for duration mutation")
        }
        segments[0]["capturedSeconds"] = capturedSeconds
        root["segments"] = segments
        let rewritten = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let output = try (rewritten as NSData).compressed(using: .lzfse) as Data
        try output.write(to: destination, options: .atomic)
    }

    static func checkReadableMatch(_ feature: SpectrumFeatures) throws {
        let frequencies = [20.0, 100, 500, 1_000, 10_000, 24_000]
        let measured = try Curve(name: "synthetic measured", points: zip(frequencies, [5.0, 5, 0, -5, 3, 3]).map {
            try CurvePoint(frequencyHz: $0.0, decibels: $0.1)
        }, source: "fixture", measurementSystem: "fixture")
        let reference = try Curve(name: "synthetic flat", points: frequencies.map {
            try CurvePoint(frequencyHz: $0, decibels: 0)
        }, source: "fixture", measurementSystem: "fixture", isReference: true)
        let headphone = Headphone(name: "fixture", owned: true, curve: measured)
        let result = Matcher().match(features: feature, headphone: headphone, reference: reference)
        try check(result.d?.isFinite == true && result.c?.isFinite == true, "manifest-expanded feature did not produce finite match values")
    }

    @MainActor
    static func singleAndLegacy(_ directory: URL) async throws {
        let model = try AppModel(directory: directory.appendingPathComponent("single-store"))
        let segment = try pcm(frames: 8_192, directory: directory, start: 0)
        var track = TrackEntry(title: "one valid segment", artist: "fixture", duration: segment.capturedSeconds)
        track.recordingSegments = [segment]
        let result = try await run(model, track)
        try check(result.error == nil && result.featurePath == result.analysisSegments[0].featurePath, "single segment lost direct reuse path")
        let files = try FileManager.default.contentsOfDirectory(atPath: model.database!.directory.appendingPathComponent("Features").path)
        try check(files.count == 1 && !files[0].contains("combined"), "single segment duplicated its feature")
        let short = try pcm(frames: 7_168, directory: directory, start: 0)
        let legacy = TrackEntry(title: "legacy short", artist: "fixture", audioPath: short.audioPath,
                                duration: short.capturedSeconds, capturedSeconds: short.capturedSeconds, isFull: true)
        let waiting = try await run(model, legacy)
        try check(waiting.error == nil && !waiting.analyzed && !waiting.isFull && waiting.recordingSegments == nil,
                  "legacy short row did not retain shape and wait")
        try check(!model.restorePendingAnalyses(), "legacy short row kept retrying")
        print("PASS production attachment: single valid artifact reused directly; legacy short waits without schema migration")
    }

    @MainActor
    static func badInputs(_ directory: URL) async throws {
        let model = try AppModel(directory: directory.appendingPathComponent("bad-store"))
        let empty = try pcm(frames: 0, directory: directory, start: 0)
        let corruptURL = directory.appendingPathComponent("invalid.caf")
        try Data("not an audio container".utf8).write(to: corruptURL)
        let corrupt = RecordingSegment(audioPath: corruptURL.path, mediaStartSeconds: 0, capturedSeconds: 1)
        for segment in [empty, corrupt] {
            var track = TrackEntry(title: "invalid fixture", artist: "fixture", duration: 1)
            track.recordingSegments = [segment]
            let result = try await run(model, track)
            try check(result.error != nil && !result.analyzed, "invalid audio silently classified as short waiting")
        }
        print("PASS production failures: empty and corrupt containers remain explicit errors")
    }
}

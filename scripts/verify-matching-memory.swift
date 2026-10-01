import Foundation
import ResonanceCore

#if MATCHING_MEMORY_VERIFICATION
/// Test-only worker instrumentation. Keeping the state in this harness means
/// the production app has no diagnostic storage or synchronization overhead.
enum MatchingMemoryProbe {
    private static let lock = NSLock()
    private static var startedCount = 0
    private static var activeCount = 0
    private static var peakActiveCount = 0
    static var workerStartHook: (() -> Void)?

    static func reset() {
        lock.lock()
        startedCount = 0
        activeCount = 0
        peakActiveCount = 0
        workerStartHook = nil
        lock.unlock()
    }

    static func started() {
        lock.lock()
        startedCount += 1
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
        let hook = workerStartHook
        lock.unlock()
        hook?()
    }

    static func ended() {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        lock.unlock()
    }

    static func snapshot() -> (started: Int, active: Int, peakActive: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (startedCount, activeCount, peakActiveCount)
    }
}
#endif

// State-only host for the production MatchingService extension. It does not
// construct the real AppModel, browser, player, capture driver, or library;
// the harness uses a temporary SQLite store only for artifact reads.
@MainActor
final class AppModel {
    var mode: WorkMode = .song
    var curves: [LibraryCurve] = []
    var headphones: [HeadphoneEntry] = []
    var tracks: [TrackEntry] = []
    var playlists: [PlaylistEntry] = []
    var selectedTrackID: UUID?
    var selectedHeadphoneID: UUID?
    var selectedPlaylistID: UUID?
    var sort: SongSort = .personal
    var includePartial = true
    var results: [MatchPresentation] = []
    var selectedResultID: String?
    var spectrumLine: [Double] = []
    var spectrumFrequencies: [Double] = []
    var status = ""
    var matching = false
    var reportedErrors: [String] = []
    var database: LocalStore?
    var matchTask: Task<Void, Never>?

    var selectedTrack: TrackEntry? { tracks.first { $0.id == selectedTrackID } }
    var selectedHeadphone: HeadphoneEntry? { headphones.first { $0.id == selectedHeadphoneID } }
    var preferredReferences: [LibraryCurve] { curves.filter { $0.isReference && $0.isPreferred == true } }

    func report(_ error: Error) {
        reportedErrors.append(error.localizedDescription)
        status = error.localizedDescription
    }
}

struct CheckFailure: Error {
    let message: String
}

@main
struct MatchingMemoryHarness {
    @MainActor
    static func main() async throws {
        try await rapidRecomputeIsSerialized()
        print("matching memory harness: PASS")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    @MainActor
    static func rapidRecomputeIsSerialized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-matching-memory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try LocalStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let frequencies = [20.0, 100.0, 500.0, 1_000.0, 10_000.0, 20_000.0]
        let measuredID = UUID()
        let referenceID = UUID()
        let headphoneID = UUID()
        let trackAID = UUID()
        let trackBID = UUID()
        let measured = LibraryCurve(
            id: measuredID,
            name: "fixture measured",
            frequencies: frequencies,
            levels: [3, 2, 1, 0, -1, -2],
            rightLevels: nil,
            source: "fixture",
            measurementSystem: "fixture",
            validMin: 20,
            validMax: 20_000,
            isReference: false,
            notes: ""
        )
        let reference = LibraryCurve(
            id: referenceID,
            name: "fixture reference",
            frequencies: frequencies,
            levels: [0, 0, 0, 0, 0, 0],
            rightLevels: nil,
            source: "fixture",
            measurementSystem: "fixture",
            validMin: 20,
            validMax: 20_000,
            isReference: true,
            notes: ""
        )
        let headphone = HeadphoneEntry(
            id: headphoneID,
            name: "fixture headphone",
            curveID: measuredID,
            referenceID: referenceID,
            owned: true
        )
        let feature = try makeFeature(recordingID: trackAID, frequencies: frequencies)
        let featureURL = directory.appendingPathComponent("fixture-feature.plist.lzfse")
        try LocalStore.writeArtifact(feature, to: featureURL)

        let trackA = TrackEntry(
            id: trackAID,
            title: "first track",
            artist: "fixture",
            featurePath: featureURL.path,
            duration: 1,
            capturedSeconds: 1,
            sampleRate: 48_000,
            channels: 1,
            isFull: true
        )
        var trackB = trackA
        trackB.id = trackBID
        trackB.title = "latest track"

        let model = AppModel()
        model.database = store
        model.curves = [measured, reference]
        model.headphones = [headphone]
        model.tracks = [trackA, trackB]
        model.mode = .song
        model.selectedTrackID = trackAID
        model.selectedHeadphoneID = headphoneID

        let releaseFirst = DispatchSemaphore(value: 0)
        MatchingMemoryProbe.reset()
        MatchingMemoryProbe.workerStartHook = {
            if MatchingMemoryProbe.snapshot().started == 1 {
                _ = releaseFirst.wait(timeout: .now() + 10)
            }
        }

        model.recompute()
        for _ in 0..<1_000 where MatchingMemoryProbe.snapshot().started == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try check(MatchingMemoryProbe.snapshot().started == 1,
                  "first production matching worker did not start")

        // A second and third recompute arrive while the first worker is held at
        // the worker-start gate. Only the newest snapshot should start a
        // replacement after the canceled worker has fully returned.
        model.selectedTrackID = trackBID
        model.recompute()
        model.recompute()
        // Give both replacement tasks a bounded chance to reach their await
        // point; a single yield can otherwise inspect the state too early.
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 1_000_000)
            if MatchingMemoryProbe.snapshot().started != 1 { break }
        }
        let blocked = MatchingMemoryProbe.snapshot()
        try check(blocked.started == 1 && blocked.active == 1 && blocked.peakActive == 1,
                  "a replacement matching worker overlapped the canceled worker")

        releaseFirst.signal()
        guard let finalTask = model.matchTask else {
            throw CheckFailure(message: "final matching task was not retained")
        }
        await finalTask.value

        for _ in 0..<100 where MatchingMemoryProbe.snapshot().started < 2 {
            await Task.yield()
        }
        let completed = MatchingMemoryProbe.snapshot()
        try check(completed.started == 2 && completed.active == 0 && completed.peakActive == 1,
                  "rapid recompute did not collapse to one replacement worker")
        try check(model.results.count == 1 && model.results[0].trackID == trackBID && model.results[0].eligible,
                  "a stale canceled result replaced the newest selection")
        try check(model.reportedErrors.isEmpty && !model.matching && model.status.isEmpty == false,
                  "canceled matching task left the model in an invalid state")
        MatchingMemoryProbe.reset()
        _ = store
    }

    static func makeFeature(recordingID: UUID, frequencies: [Double]) throws -> SpectrumFeatures {
        let coverage = try Coverage(
            kind: .complete,
            mediaDurationSeconds: 1,
            recordedDurationSeconds: 1,
            intervals: [try TimeRange(startSeconds: 0, endSeconds: 1)],
            identityConfirmed: true
        )
        let parameters = SpectrumAnalysisParameters(
            frameLength: 8_192,
            hopLength: 2_048,
            frameDurationSeconds: 8_192.0 / 48_000.0
        )
        let frame = SpectrumFrame(
            startTimeSeconds: 0,
            sampleCount: parameters.frameLength,
            powerSpectralDensityByChannel: [[1, 1, 1, 1, 1, 1]]
        )
        return SpectrumFeatures(
            recordingID: recordingID,
            sampleRate: 48_000,
            channelCount: 1,
            frequencyBinsHz: frequencies,
            frames: [frame],
            durationSeconds: 1,
            coverage: coverage,
            validMinHz: frequencies.first!,
            validMaxHz: frequencies.last!,
            frequencyValidity: .mathematicalNyquist,
            format: AudioFormatMetadata(sampleRate: 48_000, channelCount: 1),
            parameters: parameters,
            analyzerVersion: "matching-memory-fixture"
        )
    }
}

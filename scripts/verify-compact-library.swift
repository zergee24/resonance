import Foundation
import SQLite3
import CryptoKit
import ResonanceCore

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

private struct Fixture {
    let source: URL
    let trackID: UUID
    let sharedSegmentID: UUID
    let secondSegmentID: UUID
    let track2ID: UUID
    let segmentedCloneID: UUID
    let metadataOnlyID: UUID
    let deferredID: UUID
    let leafA: URL
    let leafB: URL
    let combined: URL
    let audioA: URL
    let audioB: URL
    let curveBody: Data
}

private struct AliasFixture {
    let source: URL
    let ownerID: UUID
    let cloneID: UUID
    let conflictID: UUID
    let leaf: URL
    let audio: URL
}

private final class SQLiteFixtureDatabase {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw VerificationError.failed("fixture SQLite open failed")
        }
        try execute("CREATE TABLE documents (kind TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL, modified REAL NOT NULL, PRIMARY KEY(kind,id))")
    }

    deinit { sqlite3_close(db) }

    func insert(kind: String, id: String, body: Data, modified: Double) throws {
        guard let db else { throw VerificationError.failed("fixture SQLite is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO documents(kind,id,body,modified) VALUES(?,?,?,?)", -1, &statement, nil) == SQLITE_OK else {
            throw VerificationError.failed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = body.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(body.count), transient)
        }
        sqlite3_bind_double(statement, 4, modified)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VerificationError.failed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func execute(_ sql: String) throws {
        guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw VerificationError.failed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "fixture SQLite error")
        }
    }
}

private final class SQLiteReadback {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw VerificationError.failed("output SQLite open failed")
        }
    }

    deinit { sqlite3_close(db) }

    func bodies(kind: String) throws -> [String: Data] {
        guard let db else { throw VerificationError.failed("output SQLite is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,body FROM documents WHERE kind=? ORDER BY id", -1, &statement, nil) == SQLITE_OK else {
            throw VerificationError.failed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        var result: [String: Data] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  let idBytes = sqlite3_column_text(statement, 0),
                  let bodyBytes = sqlite3_column_blob(statement, 1) else {
                throw VerificationError.failed(String(cString: sqlite3_errmsg(db)))
            }
            result[String(cString: idBytes)] = Data(bytes: bodyBytes, count: Int(sqlite3_column_bytes(statement, 1)))
        }
        return result
    }
}

@main
private struct CompactLibraryVerification {
    static func main() throws {
        let wrapper = try requireArgument(at: 1, message: "verification needs compact-library executable wrapper")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resonance-compact-library-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try makeFixture(root: root.appendingPathComponent("valid", isDirectory: true), includeInvalidRows: false)
        let before = try snapshot(fixture.source)
        let planOutput = try run(wrapper: wrapper, arguments: ["--source", fixture.source.path, "--plan"], expectedStatus: 0)
        try check(planOutput.contains("\"mode"), "plan did not return JSON")
        try check(planOutput.contains("\"plan\""), "plan mode missing")
        try check(!FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("compact-library-report.json").path), "plan wrote into source")

        let output = root.appendingPathComponent("converted", isDirectory: true)
        _ = try run(wrapper: wrapper, arguments: ["--source", fixture.source.path, "--output", output.path, "--convert"], expectedStatus: 0)
        try check(FileManager.default.fileExists(atPath: output.appendingPathComponent("library.sqlite").path), "output SQLite missing")
        try check(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Audio").path), "raw Audio was copied")
        try check(FileManager.default.fileExists(atPath: output.appendingPathComponent("Features").path), "output Features missing")

        try verifyConvertedOutput(fixture: fixture, output: output)
        let after = try snapshot(fixture.source)
        try check(before == after, "source library or referenced files changed")

        let badFixture = try makeFixture(root: root.appendingPathComponent("invalid", isDirectory: true), includeInvalidRows: true)
        let badOutput = root.appendingPathComponent("invalid-output", isDirectory: true)
        let badRun = try run(wrapper: wrapper, arguments: ["--source", badFixture.source.path, "--output", badOutput.path, "--convert"], expectedStatus: 1)
        try check(badRun.contains("0frame") || badRun.contains("0 帧"), "0frame record was not reported")
        let reportData = try Data(contentsOf: badOutput.appendingPathComponent("compact-library-report.json"))
        let reportObject = try JSONSerialization.jsonObject(with: reportData) as? [String: Any]
        try check((reportObject?["completed"] as? Bool) == false, "failed conversion was marked complete")

        let completeDeferredFixture = try makeFixture(
            root: root.appendingPathComponent("complete-deferred", isDirectory: true),
            includeInvalidRows: false,
            includeCompleteDeferred: true
        )
        let completeDeferredOutput = root.appendingPathComponent("complete-deferred-output", isDirectory: true)
        let completeDeferredRun = try run(
            wrapper: wrapper,
            arguments: ["--source", completeDeferredFixture.source.path, "--output", completeDeferredOutput.path, "--convert"],
            expectedStatus: 1
        )
        try check(completeDeferredRun.contains("coverage=complete") && completeDeferredRun.contains("deferred"), "complete coverage with deferred segment was accepted")

        let aliasFixture = try makeAliasFixture(root: root.appendingPathComponent("aliases", isDirectory: true))
        let aliasOutput = root.appendingPathComponent("aliases-output", isDirectory: true)
        let aliasRun = try run(
            wrapper: wrapper,
            arguments: ["--source", aliasFixture.source.path, "--output", aliasOutput.path, "--convert"],
            expectedStatus: 1
        )
        try check(aliasRun.contains("content hash") || aliasRun.contains("recordingID"), "conflicting alias was not rejected")
        try verifyAliasOutput(fixture: aliasFixture, output: aliasOutput)

        print("PASS plan is read-only; conversion creates an independent DB; shared leaf paths deduplicate; manifests reread; aliases require exact physical evidence; complete coverage cannot hide deferred segments; 0frame and conflicting aliases are reported")
    }

    private static func makeFixture(root: URL, includeInvalidRows: Bool, includeCompleteDeferred: Bool = false) throws -> Fixture {
        let featuresDirectory = root.appendingPathComponent("Features", isDirectory: true)
        let audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        let trackID = UUID()
        let sharedSegmentID = UUID()
        let secondSegmentID = UUID()
        let track2ID = UUID()
        let segmentedCloneID = UUID()
        let metadataOnlyID = UUID()
        let deferredID = UUID()
        let leafA = featuresDirectory.appendingPathComponent("shared.plist.lzfse")
        let leafB = featuresDirectory.appendingPathComponent("tail.plist.lzfse")
        let combined = featuresDirectory.appendingPathComponent("\(trackID.uuidString)-combined.plist.lzfse")
        let audioA = audioDirectory.appendingPathComponent("shared.caf")
        let audioB = audioDirectory.appendingPathComponent("tail.caf")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: audioA)
        try Data([0x05, 0x06, 0x07]).write(to: audioB)

        let featureA = try makeFeature(recordingID: sharedSegmentID)
        let featureB = try makeFeature(recordingID: secondSegmentID)
        try LocalStore.writeArtifact(featureA, to: leafA)
        try LocalStore.writeArtifact(featureB, to: leafB)
        let aggregate = try makeFeature(
            recordingID: trackID,
            duration: 2,
            coverageKind: includeCompleteDeferred ? .complete : .partial
        )
        let references = [
            SpectrumSegmentReference(fileName: leafA.lastPathComponent, recordingID: sharedSegmentID, mediaStartSeconds: 0, capturedSeconds: 1),
            SpectrumSegmentReference(fileName: leafB.lastPathComponent, recordingID: secondSegmentID, mediaStartSeconds: 1, capturedSeconds: 1)
        ]
        try LocalStore.writeSpectrumManifest(metadata: aggregate, segments: references, to: combined)

        let segmentA: [String: Any] = [
            "id": sharedSegmentID.uuidString,
            "audioPath": audioA.path,
            "featurePath": leafA.path,
            "mediaStartSeconds": 0.0,
            "capturedSeconds": 1.0,
            "unknownSegmentField": ["keep": true]
        ]
        var segmentB: [String: Any] = [
            "id": secondSegmentID.uuidString,
            "audioPath": audioB.path,
            "featurePath": leafB.path,
            "mediaStartSeconds": 1.0,
            "capturedSeconds": 1.0
        ]
        if includeCompleteDeferred { segmentB["featurePath"] = NSNull() }
        let trackBody: [String: Any] = [
            "id": trackID.uuidString,
            "title": "Combined fixture",
            "artist": "Verification",
            "featurePath": combined.path,
            "audioPath": audioA.path,
            "rawAudioPath": audioA.path,
            "recordingSegments": [segmentA, segmentB],
            "coverageKind": "partial",
            "opaque": ["nested": ["value": "preserve"]]
        ]
        let track2Body: [String: Any] = [
            "id": track2ID.uuidString,
            "title": "Shared leaf fixture",
            "artist": "Verification",
            "featurePath": leafA.path,
            "audioPath": audioA.path,
            "recordingSegments": [segmentA],
            "opaque": ["second": 42]
        ]
        let segmentedCloneBody: [String: Any] = [
            "id": segmentedCloneID.uuidString,
            "title": "Segmented clone",
            "artist": "Verification",
            "featurePath": combined.path,
            "audioPath": audioA.path,
            "recordingSegments": [segmentA, segmentB]
        ]
        let metadataOnlyBody: [String: Any] = [
            "id": metadataOnlyID.uuidString,
            "title": "Metadata only",
            "artist": "Verification",
            "source": "playlist metadata"
        ]
        let deferredBody: [String: Any] = [
            "id": deferredID.uuidString,
            "title": "Deferred audio",
            "artist": "Verification",
            "audioPath": audioB.path,
            "capturedSeconds": 0.5,
            "processingState": "等待后续录音"
        ]
        let curveBody: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Preserved curve",
            "unknownCurveField": ["x": 1, "y": ["z": "keep"]]
        ]
        let playlistBody: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Preserved playlist",
            "trackIDs": [trackID.uuidString, track2ID.uuidString],
            "unknownPlaylistField": "keep"
        ]

        let databaseURL = root.appendingPathComponent("library.sqlite")
        let database = try SQLiteFixtureDatabase(url: databaseURL)
        try database.insert(kind: "tracks", id: trackID.uuidString, body: try jsonData(trackBody), modified: 1)
        try database.insert(kind: "tracks", id: track2ID.uuidString, body: try jsonData(track2Body), modified: 2)
        try database.insert(kind: "tracks", id: segmentedCloneID.uuidString, body: try jsonData(segmentedCloneBody), modified: 8)
        try database.insert(kind: "tracks", id: metadataOnlyID.uuidString, body: try jsonData(metadataOnlyBody), modified: 6)
        try database.insert(kind: "tracks", id: deferredID.uuidString, body: try jsonData(deferredBody), modified: 7)
        try database.insert(kind: "curves", id: "curve-1", body: try jsonData(curveBody), modified: 3)
        try database.insert(kind: "playlists", id: "playlist-1", body: try jsonData(playlistBody), modified: 4)
        if includeInvalidRows {
            let invalidID = UUID()
            let invalidLeaf = featuresDirectory.appendingPathComponent("zero-frame.plist.lzfse")
            let invalidFeature = try makeFeature(recordingID: invalidID, frames: [])
            try LocalStore.writeArtifact(invalidFeature, to: invalidLeaf)
            let invalidBody: [String: Any] = [
                "id": invalidID.uuidString,
                "title": "Invalid zero frame",
                "artist": "Verification",
                "featurePath": invalidLeaf.path,
                "audioPath": audioB.path
            ]
            try database.insert(kind: "tracks", id: invalidID.uuidString, body: try jsonData(invalidBody), modified: 5)
        }

        return Fixture(source: root, trackID: trackID, sharedSegmentID: sharedSegmentID, secondSegmentID: secondSegmentID, track2ID: track2ID, segmentedCloneID: segmentedCloneID, metadataOnlyID: metadataOnlyID, deferredID: deferredID, leafA: leafA, leafB: leafB, combined: combined, audioA: audioA, audioB: audioB, curveBody: try jsonData(curveBody))
    }

    private static func makeFeature(
        recordingID: UUID,
        duration: Double = 1,
        coverageKind: CoverageKind = .partial,
        frames: [SpectrumFrame]? = nil
    ) throws -> SpectrumFeatures {
        let frequencies: [Double] = [20, 40, 80, 160, 320, 640, 1_280, 2_560, 5_120, 10_240, 16_000, 20_000]
        let actualFrames = frames ?? [0, 1].map { index in
            SpectrumFrame(
                // Segment artifacts use local time. The manifest reference,
                // rather than the leaf payload, supplies the media offset.
                startTimeSeconds: Double(index) * 0.25,
                sampleCount: 1_024,
                powerSpectralDensityByChannel: [frequencies.indices.map { 0.001 * Double($0 + 1 + index) }]
            )
        }
        let coverage = try Coverage(
            kind: coverageKind,
            mediaDurationSeconds: duration,
            recordedDurationSeconds: duration,
            intervals: [try TimeRange(startSeconds: 0, endSeconds: duration)],
            identityConfirmed: true
        )
        return SpectrumFeatures(
            recordingID: recordingID,
            sampleRate: 44_100,
            channelCount: 1,
            frequencyBinsHz: frequencies,
            frames: actualFrames,
            durationSeconds: duration,
            coverage: coverage,
            validMinHz: 20,
            validMaxHz: 20_000,
            frequencyValidity: .mathematicalNyquist,
            format: AudioFormatMetadata(sampleRate: 44_100, channelCount: 1),
            parameters: SpectrumAnalysisParameters(frameLength: 1_024, hopLength: 256, frameDurationSeconds: 1_024.0 / 44_100),
            analyzerVersion: "fixture-v1"
        )
    }

    private static func makeAliasFixture(root: URL) throws -> AliasFixture {
        let featuresDirectory = root.appendingPathComponent("Features", isDirectory: true)
        let audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let ownerID = UUID()
        let cloneID = UUID()
        let conflictID = UUID()
        let leaf = featuresDirectory.appendingPathComponent("legacy-shared.plist.lzfse")
        let audio = audioDirectory.appendingPathComponent("temporary.caf")
        try Data([0x01, 0x02, 0x03]).write(to: audio)
        try LocalStore.writeArtifact(try makeFeature(recordingID: ownerID), to: leaf)

        let ownerBody: [String: Any] = [
            "id": ownerID.uuidString,
            "title": "Owner title",
            "artist": "Owner artist",
            "album": "Same album",
            "neteaseID": "song-owner",
            "featurePath": leaf.path,
            "audioPath": audio.path,
            "contentSHA256": "same-content-hash",
            "duration": 1.0,
            "capturedSeconds": 1.0,
            "processingState": "已分析",
            "comparisonAllowed": true
        ]
        let cloneBody: [String: Any] = [
            "id": cloneID.uuidString,
            "title": "Clone metadata title",
            "artist": "Clone metadata artist",
            "album": "Same album",
            "featurePath": leaf.path,
            "audioPath": audio.path,
            "contentSHA256": "same-content-hash",
            "duration": 1.0,
            "capturedSeconds": 1.0,
            "processingState": "已分析",
            "comparisonAllowed": true
        ]
        let conflictBody: [String: Any] = [
            "id": conflictID.uuidString,
            "title": "Conflict metadata",
            "artist": "Other artist",
            "album": "Same album",
            "neteaseID": "song-conflict",
            "featurePath": leaf.path,
            "audioPath": audio.path,
            "contentSHA256": "different-content-hash",
            "duration": 1.0,
            "capturedSeconds": 1.0,
            "processingState": "已分析",
            "comparisonAllowed": true
        ]
        let database = try SQLiteFixtureDatabase(url: root.appendingPathComponent("library.sqlite"))
        try database.insert(kind: "tracks", id: ownerID.uuidString, body: try jsonData(ownerBody), modified: 1)
        try database.insert(kind: "tracks", id: cloneID.uuidString, body: try jsonData(cloneBody), modified: 2)
        try database.insert(kind: "tracks", id: conflictID.uuidString, body: try jsonData(conflictBody), modified: 3)
        return AliasFixture(source: root, ownerID: ownerID, cloneID: cloneID, conflictID: conflictID, leaf: leaf, audio: audio)
    }

    private static func verifyAliasOutput(fixture: AliasFixture, output: URL) throws {
        let database = try SQLiteReadback(url: output.appendingPathComponent("library.sqlite"))
        let tracks = try database.bodies(kind: "tracks")
        guard let ownerData = tracks[fixture.ownerID.uuidString],
              let cloneData = tracks[fixture.cloneID.uuidString],
              let conflictData = tracks[fixture.conflictID.uuidString],
              let owner = jsonObject(ownerData),
              let clone = jsonObject(cloneData),
              let conflict = jsonObject(conflictData) else {
            throw VerificationError.failed("alias fixture rows missing")
        }
        guard let ownerPath = owner["featurePath"] as? String,
              let clonePath = clone["featurePath"] as? String else {
            throw VerificationError.failed("legal alias was not converted")
        }
        try check(ownerPath != clonePath, "legacy alias incorrectly reused the owner recordingID leaf")
        try check(ownerPath != fixture.leaf.path && clonePath != fixture.leaf.path, "legal alias retained the source feature path")
        try check((conflict["featurePath"] as? String) == fixture.leaf.path, "conflicting alias was rewritten")
        let ownerCompact = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: ownerPath))
        let cloneCompact = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: clonePath))
        try check(ownerCompact.recordingID == fixture.ownerID, "owner artifact recordingID changed")
        try check(cloneCompact.recordingID == fixture.cloneID, "legacy clone leaf did not receive the clone recordingID")
        try FileManager.default.removeItem(at: fixture.audio)
        let recoveredClone = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: clonePath))
        try check(recoveredClone.recordingID == fixture.cloneID, "clone artifact depended on temporary PCM after conversion")
        let reportData = try Data(contentsOf: output.appendingPathComponent("compact-library-report.json"))
        let report = try JSONSerialization.jsonObject(with: reportData) as? [String: Any]
        try check((report?["completed"] as? Bool) == false, "conflicting alias conversion was marked complete")
        try check((report?["verified"] as? Bool) == true, "successfully generated alias artifact was not verified")
        let trackReports = report?["tracks"] as? [[String: Any]] ?? []
        let cloneReport = trackReports.first { ($0["trackID"] as? String) == fixture.cloneID.uuidString }
        try check((cloneReport?["sourceArtifactRecordingID"] as? String) == fixture.ownerID.uuidString, "clone source artifact ID was not retained in the report")
    }

    private static func verifyConvertedOutput(fixture: Fixture, output: URL) throws {
        let database = try SQLiteReadback(url: output.appendingPathComponent("library.sqlite"))
        let tracks = try database.bodies(kind: "tracks")
        try check(tracks.count == 5, "track document count changed")
        guard let firstData = tracks[fixture.trackID.uuidString],
              let secondData = tracks[fixture.track2ID.uuidString],
              let segmentedCloneData = tracks[fixture.segmentedCloneID.uuidString],
              let first = jsonObject(firstData),
              let second = jsonObject(secondData),
              let segmentedClone = jsonObject(segmentedCloneData) else {
            throw VerificationError.failed("converted track bodies missing")
        }
        try check(first["opaque"] as? [String: Any] != nil, "unknown TrackEntry field was lost")
        try check((first["coverageKind"] as? String) == "partial", "coverage metadata changed")
        guard let firstSegments = first["recordingSegments"] as? [[String: Any]], firstSegments.count == 2 else {
            throw VerificationError.failed("converted segment mapping missing")
        }
        guard let firstPath = firstSegments[0]["featurePath"] as? String,
              let secondPath = firstSegments[1]["featurePath"] as? String,
              let combinedPath = first["featurePath"] as? String else {
            throw VerificationError.failed("converted feature paths missing")
        }
        try check(firstPath != combinedPath, "segment path was not rewritten as a leaf")
        guard let secondSegments = second["recordingSegments"] as? [[String: Any]],
              let secondSharedPath = secondSegments.first?["featurePath"] as? String else {
            throw VerificationError.failed("shared segment mapping missing")
        }
        try check(firstPath == secondSharedPath, "shared leaf path was not deduplicated")
        try check(FileManager.default.fileExists(atPath: firstPath), "compact shared leaf missing")
        try check(FileManager.default.fileExists(atPath: secondPath), "compact tail leaf missing")
        try check(FileManager.default.fileExists(atPath: combinedPath), "compact combined manifest missing")
        try check(firstPath != fixture.leafA.path && secondPath != fixture.leafB.path, "source feature path remained in converted track")
        try check((first["audioPath"] as? String) == fixture.audioA.path, "audio source path was not retained")
        guard let metadataOnlyData = tracks[fixture.metadataOnlyID.uuidString],
              let deferredData = tracks[fixture.deferredID.uuidString],
              let metadataOnly = jsonObject(metadataOnlyData),
              let deferred = jsonObject(deferredData) else {
            throw VerificationError.failed("metadata-only or deferred track was lost")
        }
        try check(metadataOnly["featurePath"] == nil, "metadata-only row was marked analyzed")
        try check(deferred["featurePath"] == nil, "deferred row was marked analyzed")

        let combined = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: combinedPath))
        try check(combined.recordingID == fixture.trackID, "combined recording ID changed")
        try check(!combined.frames.isEmpty, "combined manifest did not reread actual segments")
        let shared = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: firstPath))
        try check(shared.recordingID == fixture.sharedSegmentID, "shared leaf recording ID changed")
        try check(shared.compactStorage?.version == CompactSpectrum.formatVersion, "compact metadata missing")
        guard let cloneCombinedPath = segmentedClone["featurePath"] as? String else {
            throw VerificationError.failed("segmented alias combined path missing")
        }
        try check(cloneCombinedPath != combinedPath, "segmented alias reused owner combined manifest")
        let cloneCombined = try LocalStore.readArtifact(SpectrumFeatures.self, from: URL(fileURLWithPath: cloneCombinedPath))
        try check(cloneCombined.recordingID == fixture.segmentedCloneID, "segmented alias combined recording ID was not rewritten")

        let curves = try database.bodies(kind: "curves")
        try check(curves.values.contains(fixture.curveBody), "curve document was not preserved exactly")
        try check(curves.count == 1, "curve documents changed")
        let compactLeafNames = try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("Features").path).filter { $0.hasSuffix(".compact.plist.lzfse") }
        try check(compactLeafNames.count == 2, "duplicate source leaf was converted more than once")
        let reportData = try Data(contentsOf: output.appendingPathComponent("compact-library-report.json"))
        let report = try JSONSerialization.jsonObject(with: reportData) as? [String: Any]
        try check((report?["completed"] as? Bool) == true, "metadata-only/deferred rows blocked the complete conversion")
        try check((report?["verified"] as? Bool) == true, "compact artifact verification was not recorded")
        let trackReports = report?["tracks"] as? [[String: Any]] ?? []
        let segmentedCloneReport = trackReports.first { ($0["trackID"] as? String) == fixture.segmentedCloneID.uuidString }
        try check((segmentedCloneReport?["sourceArtifactRecordingID"] as? String) == fixture.trackID.uuidString, "segmented alias source artifact ID was not retained in the report")
    }

    private static func run(wrapper: String, arguments: [String], expectedStatus: Int32) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [wrapper] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try check(process.terminationStatus == expectedStatus, "unexpected status \(process.terminationStatus) for \(arguments.joined(separator: " "))\n\(output)")
        return output
    }

    private static func snapshot(_ root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw VerificationError.failed("source snapshot enumeration failed")
        }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            result[url.path.replacingOccurrences(of: root.path + "/", with: "")] = digest
        }
        return result
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func requireArgument(at index: Int, message: String) throws -> String {
        guard CommandLine.arguments.count > index else { throw VerificationError.failed(message) }
        return CommandLine.arguments[index]
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError.failed(message) }
    }
}

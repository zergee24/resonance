import Foundation

@main
struct SystemPlayerReaderProbe {
    static func main() async throws {
        try verifyDecodeContract()
        try await verifyPlatformAndResourceErrors()

        guard #available(macOS 15.0, *) else {
            print("SKIP live SystemPlayer probe: macOS 15 or later is required by the helper")
            return
        }

        try await verifyTimeoutAndOutputLimit()

        guard CommandLine.arguments.count > 1 else {
            throw ProbeFailure("usage: system-player-probe <SystemPlayer resource directory>")
        }
        let resourceDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let reader = SystemPlayerReader(resourceDirectory: resourceDirectory)
        let startedAt = Date()
        guard let state = try await reader.read() else {
            throw ProbeFailure("live MediaRemote response contained no track metadata; leave a paused NetEase song selected and retry")
        }
        guard state.playing == false else {
            throw ProbeFailure("live probe expected the current NetEase song to be paused; no playback action was sent")
        }
        guard state.bundleIdentifier?.hasPrefix("com.netease.") == true else {
            throw ProbeFailure("live source was not NetEase: \(state.bundleIdentifier ?? "missing")")
        }
        try require(state.title?.isEmpty == false, "live state has no title")
        try require(state.artist?.isEmpty == false, "live state has no artist")
        try require((state.processIdentifier ?? 0) > 0, "live state has no process identifier")
        try require(state.contentItemIdentifier?.isEmpty == false, "live state has no content item identifier")
        print("PASS live paused NetEase read: \(state.title ?? "<unknown>") — \(state.artist ?? "<unknown>") [\(state.bundleIdentifier ?? "<unknown>")] in \(String(format: "%.3fs", Date().timeIntervalSince(startedAt)))")
    }

    private static func verifyDecodeContract() throws {
        let nullState = try SystemPlayerState.decode(Data("null".utf8))
        let emptyState = try SystemPlayerState.decode(Data("{}".utf8))
        try require(nullState == nil, "JSON null must decode as no state")
        try require(emptyState == nil, "an object without metadata must decode as no state")

        let fixture = """
        {"title":"完整标题 / VIP","artist":"准确演唱者","album":"专辑","duration":321.5,"elapsedTime":12.25,"elapsedTimeNow":13.75,"playing":true,"bundleIdentifier":"com.example.player","processIdentifier":1234,"contentItemIdentifier":"01234567-89AB-CDEF-0123-456789ABCDEF","artworkData":"ignored"}
        """
        guard let state = try SystemPlayerState.decode(Data(fixture.utf8)) else {
            throw ProbeFailure("complete fixture unexpectedly decoded as nil")
        }
        try require(state.title == "完整标题 / VIP", "full title was not preserved")
        try require(state.artist == "准确演唱者", "artist was not preserved")
        try require(state.duration == 321.5, "duration was not preserved")
        try require(state.currentTime == 13.75, "elapsedTimeNow must take precedence over elapsedTime")
        try require(state.playing == true, "playing flag was not preserved")
        try require(state.bundleIdentifier == "com.example.player", "source bundle was not preserved")
        try require(state.processIdentifier == 1234, "source process identifier was not preserved")
        try require(state.contentItemIdentifier == "01234567-89AB-CDEF-0123-456789ABCDEF", "content item identifier was not preserved")

        let missingProgress = "{\"title\":\"暂停曲\",\"artist\":\"歌手\",\"playing\":false}"
        guard let paused = try SystemPlayerState.decode(Data(missingProgress.utf8)) else {
            throw ProbeFailure("metadata fixture with missing progress unexpectedly decoded as nil")
        }
        try require(paused.currentTime == nil, "missing progress must stay nil")
        try require(paused.playing == false, "explicit paused flag must stay false")

        let missingPlaying = "{\"title\":\"未知播放状态\"}"
        guard let unknown = try SystemPlayerState.decode(Data(missingPlaying.utf8)) else {
            throw ProbeFailure("metadata fixture with missing playing unexpectedly decoded as nil")
        }
        try require(unknown.playing == nil, "missing playing must not become false")

        do {
            _ = try SystemPlayerState.decode(Data("not-json".utf8))
            throw ProbeFailure("invalid JSON unexpectedly decoded")
        } catch let error as SystemPlayerReaderError {
            try require(error == .invalidResponse, "invalid JSON returned the wrong error")
        }
        print("PASS decode contract: null/empty state, exact title/artist/source, elapsedTimeNow preference, optional progress")
    }

    private static func verifyPlatformAndResourceErrors() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("resonance-missing-system-player-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: missing) }

        do {
            _ = try await SystemPlayerReader(resourceDirectory: missing).read()
            throw ProbeFailure("missing resources unexpectedly produced a state")
        } catch let error as SystemPlayerReaderError {
            if #available(macOS 15.0, *) {
                try require(error == .missingResource("mediaremote-mini.pl"), "missing resource returned the wrong error")
            } else {
                try require(error == .unsupportedOperatingSystem, "old macOS returned the wrong fallback error")
            }
        }
        print("PASS fallback errors: missing resources and macOS version are explicit")
    }

    private static func verifyTimeoutAndOutputLimit() async throws {
        let cancellationDirectory = try makeFixtureDirectory(script: "use strict; select(undef, undef, undef, 5); print '{}';")
        defer { try? FileManager.default.removeItem(at: cancellationDirectory) }
        let cancellationReader = SystemPlayerReader(resourceDirectory: cancellationDirectory)
        let cancellationTask = Task { try await cancellationReader.read() }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancellationReader.cancel()
        do {
            _ = try await cancellationTask.value
            throw ProbeFailure("cancelled helper unexpectedly completed")
        } catch let error as SystemPlayerReaderError {
            try require(error == .helperCancelled, "cancelled helper returned the wrong error: \(error)")
        }

        let timeoutDirectory = try makeFixtureDirectory(script: "use strict; select(undef, undef, undef, 5); print '{}';")
        defer { try? FileManager.default.removeItem(at: timeoutDirectory) }
        let timeoutStarted = Date()
        do {
            _ = try await SystemPlayerReader(resourceDirectory: timeoutDirectory).read()
            throw ProbeFailure("sleeping helper unexpectedly completed")
        } catch let error as SystemPlayerReaderError {
            try require(error == .helperTimedOut, "sleeping helper returned the wrong error: \(error)")
            try require(Date().timeIntervalSince(timeoutStarted) < 4.5, "helper timeout exceeded the expected bound")
        }

        let largeDirectory = try makeFixtureDirectory(script: "use strict; print 'A' x (3 * 1024 * 1024 + 4096);")
        defer { try? FileManager.default.removeItem(at: largeDirectory) }
        do {
            _ = try await SystemPlayerReader(resourceDirectory: largeDirectory).read()
            throw ProbeFailure("oversized helper unexpectedly completed")
        } catch let error as SystemPlayerReaderError {
            try require(error == .outputTooLarge, "oversized helper returned the wrong error: \(error)")
        }
        print("PASS helper safety: timeout and 3 MB stdout limit terminate the child")
    }

    private static func makeFixtureDirectory(script: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("resonance-system-player-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: directory.appendingPathComponent("mediaremote-mini.pl"))
        try Data("fixture dylib is intentionally unused by this script".utf8)
            .write(to: directory.appendingPathComponent("MediaRemoteMini.dylib"))
        return directory
    }
}

private struct ProbeFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProbeFailure(message) }
}

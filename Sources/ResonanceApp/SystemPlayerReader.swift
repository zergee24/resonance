import Foundation

/// The read-only state exposed by macOS's Now Playing service.
///
/// `currentTime` is taken from `elapsedTimeNow` when the adapter supplies it;
/// it is never projected locally between reads.  Missing fields stay nil so
/// callers can distinguish an unavailable value from an actual false/zero.
public struct SystemPlayerState: Equatable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: Double?
    public let currentTime: Double?
    public let playing: Bool?
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let contentItemIdentifier: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        currentTime: Double? = nil,
        playing: Bool? = nil,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        contentItemIdentifier: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.currentTime = currentTime
        self.playing = playing
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.contentItemIdentifier = contentItemIdentifier
    }

    /// Decode one adapter response.  A null response, or an object without
    /// any track metadata, means that no system player is currently available.
    public static func decode(_ data: Data) throws -> SystemPlayerState? {
        let raw: RawResponse?
        do {
            raw = try JSONDecoder().decode(RawResponse?.self, from: data)
        } catch {
            throw SystemPlayerReaderError.invalidResponse
        }
        guard let raw else { return nil }

        let title = optionalText(raw.title)
        let artist = optionalText(raw.artist)
        let album = optionalText(raw.album)
        let contentItemIdentifier = optionalText(raw.contentItemIdentifier)
        guard title != nil || artist != nil || album != nil || contentItemIdentifier != nil else {
            return nil
        }

        let duration = finiteNonNegative(raw.duration)
        // The adapter's `elapsedTimeNow` is the live anchor enabled by the
        // now option.  Fall back to elapsedTime only when it is absent.
        let currentTime = finiteNonNegative(raw.elapsedTimeNow) ?? finiteNonNegative(raw.elapsedTime)
        let processIdentifier = raw.processIdentifier.flatMap { value -> Int32? in
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value > 0,
                  value <= Double(Int32.max) else {
                return nil
            }
            return Int32(value)
        }

        return SystemPlayerState(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            currentTime: currentTime,
            playing: raw.playing,
            bundleIdentifier: optionalText(raw.bundleIdentifier),
            processIdentifier: processIdentifier,
            contentItemIdentifier: contentItemIdentifier
        )
    }

    private struct RawResponse: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTimeNow: Double?
        let elapsedTime: Double?
        let playing: Bool?
        let bundleIdentifier: String?
        let processIdentifier: Double?
        let contentItemIdentifier: String?

        private enum CodingKeys: String, CodingKey {
            case title
            case artist
            case album
            case duration
            case elapsedTimeNow
            case elapsedTime
            case playing
            case bundleIdentifier
            case processIdentifier
            case contentItemIdentifier
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            artist = try container.decodeIfPresent(String.self, forKey: .artist)
            album = try container.decodeIfPresent(String.self, forKey: .album)
            duration = try container.decodeIfPresent(Double.self, forKey: .duration)
            elapsedTimeNow = try container.decodeIfPresent(Double.self, forKey: .elapsedTimeNow)
            elapsedTime = try container.decodeIfPresent(Double.self, forKey: .elapsedTime)
            playing = try container.decodeIfPresent(Bool.self, forKey: .playing)
            bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            processIdentifier = try container.decodeIfPresent(Double.self, forKey: .processIdentifier)
            contentItemIdentifier = try container.decodeIfPresent(String.self, forKey: .contentItemIdentifier)
        }
    }

    private static func optionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func finiteNonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

public enum SystemPlayerReaderError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedOperatingSystem
    case missingResource(String)
    case helperLaunchFailed
    case helperTimedOut
    case helperCancelled
    case outputTooLarge
    case helperFailed
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperatingSystem:
            return "系统播放器读取需要 macOS 15 或更高版本"
        case let .missingResource(name):
            return "系统播放器读取资源缺失：\(name)"
        case .helperLaunchFailed:
            return "系统播放器读取器无法启动"
        case .helperTimedOut:
            return "系统播放器读取超时"
        case .helperCancelled:
            return "系统播放器读取已取消"
        case .outputTooLarge:
            return "系统播放器读取结果超过大小限制"
        case .helperFailed:
            return "系统播放器读取器执行失败"
        case .invalidResponse:
            return "系统播放器返回了无法解析的数据"
        }
    }
}

/// A single, read-only snapshot reader for the macOS Now Playing service.
///
/// The helper is intentionally not a polling loop.  The owner decides when
/// to call `read()` (normally about once per second) and can call `cancel()`
/// while stopping observation.
public final class SystemPlayerReader: @unchecked Sendable {
    public static let helperTimeout: TimeInterval = 2.5
    public static let maximumOutputBytes = 3 * 1024 * 1024

    public let resourceDirectory: URL

    private let stateLock = NSLock()
    private var activeControl: ProcessControl?

    public init(resourceDirectory: URL? = nil) {
        self.resourceDirectory = resourceDirectory
            ?? Bundle.main.resourceURL?.appendingPathComponent("SystemPlayer", isDirectory: true)
            ?? URL(fileURLWithPath: "/__resonance_missing_system_player_resources", isDirectory: true)
    }

    /// Reads one state in a utility task.  No AppleScript or UI action is
    /// performed, and artwork is never retained or emitted.
    public func read() async throws -> SystemPlayerState? {
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let worker = Task.detached(priority: .utility) { [self] in
                try self.readSynchronously()
            }
            return try await worker.value
        }, onCancel: {
            self.cancel()
        })
    }

    /// Cancels the active helper process, if a read is in progress.
    public func cancel() {
        stateLock.lock()
        let control = activeControl
        stateLock.unlock()
        control?.cancel()
    }

    private func readSynchronously() throws -> SystemPlayerState? {
        guard #available(macOS 15.0, *) else {
            throw SystemPlayerReaderError.unsupportedOperatingSystem
        }

        let script = resourceDirectory.appendingPathComponent("mediaremote-mini.pl")
        let dylib = resourceDirectory.appendingPathComponent("MediaRemoteMini.dylib")
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: script.path) else {
            throw SystemPlayerReaderError.missingResource("mediaremote-mini.pl")
        }
        guard fileManager.isReadableFile(atPath: dylib.path) else {
            throw SystemPlayerReaderError.missingResource("MediaRemoteMini.dylib")
        }

        let control = ProcessControl()
        setActive(control)
        defer { clearActive(control) }

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, dylib.path, "adapter_get_env"]
        // The helper only needs its one adapter option.  Do not leak the app's
        // environment into the private adapter invocation.
        process.environment = ["MEDIAREMOTEADAPTER_OPTION_now": "1"]
        process.standardOutput = outputPipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        control.install(process)

        let timeoutWork = DispatchWorkItem {
            control.timeout()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.helperTimeout,
            execute: timeoutWork
        )
        defer { timeoutWork.cancel() }

        do {
            try process.run()
        } catch {
            control.finish()
            throw SystemPlayerReaderError.helperLaunchFailed
        }

        if control.isCancelled {
            process.terminate()
        }

        var output = Data()
        var outputTooLarge = false
        do {
            while let chunk = try outputPipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if output.count + chunk.count > Self.maximumOutputBytes {
                    outputTooLarge = true
                    control.outputTooLarge()
                    break
                }
                output.append(chunk)
            }
        } catch {
            control.cancel()
        }

        process.waitUntilExit()
        outputPipe.fileHandleForReading.closeFile()
        control.finish()

        if control.isTimedOut {
            throw SystemPlayerReaderError.helperTimedOut
        }
        if control.isCancelled {
            throw SystemPlayerReaderError.helperCancelled
        }
        if outputTooLarge || control.isOutputTooLarge {
            throw SystemPlayerReaderError.outputTooLarge
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SystemPlayerReaderError.helperFailed
        }
        return try SystemPlayerState.decode(output)
    }

    private func setActive(_ control: ProcessControl) {
        stateLock.lock()
        activeControl = control
        stateLock.unlock()
    }

    private func clearActive(_ control: ProcessControl) {
        stateLock.lock()
        if activeControl === control {
            activeControl = nil
        }
        stateLock.unlock()
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var tooLarge = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    var isOutputTooLarge: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tooLarge
    }

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    func timeout() {
        lock.lock()
        guard process != nil else {
            lock.unlock()
            return
        }
        timedOut = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    func outputTooLarge() {
        lock.lock()
        tooLarge = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

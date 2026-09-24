import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation

/// The externally visible state of the process-tap capture session.
@available(macOS 14.2, *)
public enum AudioCaptureStatus: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case failed(String)
}

/// Errors raised while setting up a process-tap capture session.
@available(macOS 14.2, *)
public enum AudioCaptureError: Error, LocalizedError, Equatable {
    case alreadyRecording
    case startInProgress
    case startCancelled
    case startTimeout
    case invalidProcessID
    case processNotFound(pid_t)
    case invalidDestination(URL)
    case invalidTapID
    case processLookup(OSStatus)
    case tapCreation(OSStatus)
    case aggregateCreation(OSStatus)
    case streamFormat(OSStatus)
    case unsupportedAudioFormat(String)
    case audioFile(String)
    case ioProcCreation(OSStatus)
    case deviceStart(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "An audio capture is already running."
        case .startInProgress:
            return "An audio capture setup is already in progress."
        case .startCancelled:
            return "Audio capture setup was cancelled before it completed."
        case .startTimeout:
            return "Audio capture setup timed out while Core Audio was starting."
        case .invalidProcessID:
            return "The target process ID is invalid."
        case let .processNotFound(pid):
            return "No Core Audio process object was found for process \(pid)."
        case let .invalidDestination(url):
            return "The destination must be a writable .caf or .wav URL: \(url.path)"
        case .invalidTapID:
            return "Core Audio returned an invalid process tap ID."
        case let .processLookup(status):
            return "Core Audio process lookup failed (OSStatus \(status))."
        case let .tapCreation(status):
            return "Core Audio process tap creation failed (OSStatus \(status))."
        case let .aggregateCreation(status):
            return "The private tap aggregate device could not be created (OSStatus \(status))."
        case let .streamFormat(status):
            return "The tap aggregate stream format could not be read (OSStatus \(status))."
        case let .unsupportedAudioFormat(message):
            return "Unsupported tap audio format: \(message)"
        case let .audioFile(message):
            return "The capture file could not be opened: \(message)"
        case let .ioProcCreation(status):
            return "The aggregate device IOProc could not be created (OSStatus \(status))."
        case let .deviceStart(status):
            return "The aggregate device could not be started (OSStatus \(status))."
        }
    }
}

/// The observable evidence produced by a stopped capture.
@available(macOS 14.2, *)
public struct CaptureSummary {
    public let destination: URL
    public let sampleRate: Double
    public let channelCount: Int
    public let isInterleaved: Bool
    public let formatID: UInt32
    public let capturedFrames: Int64
    public let droppedFrames: UInt64
    public let zeroDataFrames: UInt64
    public let callbackCount: UInt64
    public let formatMismatchFrames: UInt64
    public let duration: TimeInterval
    public let peakLevel: Float
    public let writerError: String?

    public var hasAudioData: Bool {
        capturedFrames > 0 && zeroDataFrames < UInt64(capturedFrames)
    }

    public init(
        destination: URL,
        sampleRate: Double,
        channelCount: Int,
        isInterleaved: Bool,
        formatID: UInt32,
        capturedFrames: Int64,
        droppedFrames: UInt64,
        zeroDataFrames: UInt64,
        callbackCount: UInt64,
        formatMismatchFrames: UInt64,
        duration: TimeInterval,
        peakLevel: Float,
        writerError: String?
    ) {
        self.destination = destination
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isInterleaved = isInterleaved
        self.formatID = formatID
        self.capturedFrames = capturedFrames
        self.droppedFrames = droppedFrames
        self.zeroDataFrames = zeroDataFrames
        self.callbackCount = callbackCount
        self.formatMismatchFrames = formatMismatchFrames
        self.duration = duration
        self.peakLevel = peakLevel
        self.writerError = writerError
    }
}

/// Captures the output of one Core Audio process into a local CAF/WAV file.
///
/// The class deliberately does not open the microphone, capture the system-wide
/// mix, or use a player-specific API. `start(pid:destination:)` resolves the
/// supplied PID to a Core Audio process object and installs a private process
/// tap in a private aggregate device. The realtime IOProc only copies PCM into
/// a bounded ring; file encoding and meter work happen on a utility queue.
@available(macOS 14.2, *)
@MainActor
public final class AudioCapture: ObservableObject {
    @Published public private(set) var status: AudioCaptureStatus = .idle
    @Published public private(set) var meter: Float = 0
    @Published public private(set) var isRecording = false
    /// Receives the summary when the meter detects a writer failure and stops
    /// the session automatically. User-requested `stop()` does not call this.
    public var onUnexpectedStop: ((CaptureSummary) -> Void)?

    private var session: CaptureSession?
    private var meterTimer: Timer?
    private let setupQueue = DispatchQueue(
        label: "com.resonance.audio-capture.setup",
        qos: .userInitiated
    )
    private var activeStartID: UUID?
    private var pendingStartOperation: CaptureStartOperation?

    public init() {}

    public func start(pid: pid_t, destination: URL) async throws {
        guard session == nil else {
            throw AudioCaptureError.alreadyRecording
        }
        guard activeStartID == nil else {
            throw AudioCaptureError.startInProgress
        }

        let startID = UUID()
        activeStartID = startID
        status = .starting
        meter = 0

        let operation = CaptureStartOperation(
            pid: pid,
            destination: destination,
            setupQueue: setupQueue
        ) { [weak self] in
            // Timeout and cancellation never destroy a session from the
            // timeout queue. The setup queue performs late cleanup, then
            // releases this lease so a later start cannot overlap Core Audio
            // object creation.
            Task { @MainActor [weak self] in
                guard let self, self.activeStartID == startID else { return }
                self.activeStartID = nil
            }
        }
        pendingStartOperation = operation
        defer {
            // Dropping this reference does not release activeStartID. A
            // cancelled or timed-out setup still owns the start lease until
            // its setup-queue cleanup callback runs.
            if pendingStartOperation === operation {
                pendingStartOperation = nil
            }
        }

        do {
            let newSession = try await operation.run()
            guard activeStartID == startID else {
                _ = newSession.stop()
                throw AudioCaptureError.startTimeout
            }
            activeStartID = nil
            session = newSession
            isRecording = true
            status = .recording
            startMeterTimer()
        } catch {
            isRecording = false
            if case AudioCaptureError.startCancelled = error {
                status = .idle
            } else {
                status = .failed(error.localizedDescription)
            }
            if case AudioCaptureError.startTimeout = error {
                // Keep activeStartID until the setup queue has cleaned up a
                // late Core Audio result. This rejects overlapping starts.
            } else if case AudioCaptureError.startCancelled = error {
                // Cancellation has the same late-cleanup lease as timeout.
            } else if activeStartID == startID {
                activeStartID = nil
            }
            throw error
        }
    }

    /// Cancels a setup that is still waiting for Core Audio to start.
    ///
    /// This does not stop an already-recording session; call `stop()` for
    /// that. The method returns immediately while any late Core Audio result
    /// remains owned and cleaned up by the original setup queue.
    public func cancelPendingStart() {
        guard session == nil else { return }
        pendingStartOperation?.cancel()
    }

    @discardableResult
    public func stop() -> CaptureSummary? {
        guard let session else {
            return nil
        }

        status = .stopping
        meterTimer?.invalidate()
        meterTimer = nil
        self.session = nil
        isRecording = false
        meter = 0

        let summary = session.stop()
        if let writerError = summary.writerError {
            status = .failed(writerError)
        } else {
            status = .idle
        }
        return summary
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let session = self.session else {
                    self.meter = 0
                    return
                }
                self.meter = session.metrics.snapshot().peakLevel
                if session.writerError != nil {
                    guard let summary = self.stop() else { return }
                    self.onUnexpectedStop?(summary)
                }
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    deinit {
        meterTimer?.invalidate()
        _ = session?.stop()
    }
}

@available(macOS 14.2, *)
private final class CaptureStartOperation {
    private let stateMachine: CaptureStartStateMachine<CaptureSession>

    init(
        pid: pid_t,
        destination: URL,
        setupQueue: DispatchQueue,
        onLateCleanupFinished: @escaping () -> Void
    ) {
        stateMachine = CaptureStartStateMachine(
            setupQueue: setupQueue,
            timeout: .seconds(10),
            setup: {
                let session = try CaptureSession(pid: pid, destination: destination)
                try session.start()
                return session
            },
            cleanup: { session in
                // This closure is called from the original setup queue after
                // a blocking Core Audio call has returned.
                _ = session.stop()
            },
            onLateCleanupFinished: onLateCleanupFinished
        )
    }

    func run() async throws -> CaptureSession {
        try await stateMachine.run()
    }

    func cancel() {
        stateMachine.cancel()
    }
}

/// Owns the await, timeout/cancellation state, and late cleanup for one setup
/// operation. The generic result lets the probe exercise these races without
/// constructing real Core Audio objects.
@available(macOS 14.2, *)
final class CaptureStartStateMachine<Value> {
    private enum State {
        case pending
        case timedOut
        case cancelled
        case completed
    }

    private let setupQueue: DispatchQueue
    private let timeoutInterval: DispatchTimeInterval
    private let setup: () throws -> Value
    private let cleanup: (Value) -> Void
    private let onLateCleanupFinished: () -> Void
    private let timeoutQueue = DispatchQueue(
        label: "com.resonance.audio-capture.timeout",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var state: State = .pending
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTimer: DispatchSourceTimer?
    private var launched = false

    init(
        setupQueue: DispatchQueue,
        timeout: DispatchTimeInterval,
        setup: @escaping () throws -> Value,
        cleanup: @escaping (Value) -> Void,
        onLateCleanupFinished: @escaping () -> Void
    ) {
        self.setupQueue = setupQueue
        self.timeoutInterval = timeout
        self.setup = setup
        self.cleanup = cleanup
        self.onLateCleanupFinished = onLateCleanupFinished
    }

    func run() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            precondition(!launched, "CaptureStartStateMachine.run() may only be called once")
            launched = true
            self.continuation = continuation
            stateLock.unlock()

            schedule()
        }
    }

    func cancel() {
        var continuationToResume: CheckedContinuation<Value, Error>?
        stateLock.lock()
        guard state == .pending else {
            stateLock.unlock()
            return
        }
        state = .cancelled
        continuationToResume = continuation
        continuation = nil
        timeoutTimer?.cancel()
        timeoutTimer = nil
        stateLock.unlock()

        // This only resolves the caller's await. The setup queue remains the
        // owner of any Core Audio object that may still be inside setup.
        continuationToResume?.resume(throwing: AudioCaptureError.startCancelled)
    }

    private func schedule() {
        let timer = DispatchSource.makeTimerSource(queue: timeoutQueue)
        timer.setEventHandler { [weak self] in
            self?.timeout()
        }
        timer.schedule(deadline: .now() + timeoutInterval, leeway: .milliseconds(100))

        stateLock.lock()
        if state == .pending {
            timeoutTimer = timer
            // Balance the source's initial suspension while holding the state
            // lock so cancellation cannot leave an unowned timer behind.
            timer.resume()
        } else {
            // Dispatch sources must be resumed exactly once even when a
            // concurrent cancellation wins before the timer is installed.
            timer.resume()
            timer.cancel()
        }
        stateLock.unlock()

        // Core Audio setup, including AudioDeviceStart, is deliberately
        // isolated here. A stuck HAL mach_msg therefore cannot block the UI.
        setupQueue.async { [self] in
            execute()
        }
    }

    private func execute() {
        do {
            finish(.success(try setup()))
        } catch {
            finish(.failure(error))
        }
    }

    private func timeout() {
        var continuationToResume: CheckedContinuation<Value, Error>?
        stateLock.lock()
        guard state == .pending else {
            stateLock.unlock()
            return
        }
        state = .timedOut
        continuationToResume = continuation
        continuation = nil
        stateLock.unlock()

        // This only resolves the caller's await. It never touches a session
        // that may still be inside AudioDeviceStart; execute() owns late
        // cleanup on the setup queue.
        continuationToResume?.resume(throwing: AudioCaptureError.startTimeout)
    }

    private func finish(_ result: Result<Value, Error>) {
        var continuationToResume: CheckedContinuation<Value, Error>?
        var valueToClean: Value?
        var notifyLateCleanup = false

        stateLock.lock()
        switch state {
        case .pending:
            state = .completed
            continuationToResume = continuation
            continuation = nil
            timeoutTimer?.cancel()
            timeoutTimer = nil
        case .timedOut, .cancelled:
            state = .completed
            if case let .success(value) = result {
                valueToClean = value
            }
            timeoutTimer?.cancel()
            timeoutTimer = nil
            notifyLateCleanup = true
        case .completed:
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        if let valueToClean {
            // This is executed by the setup queue after the blocking start
            // call has returned, so teardown cannot race the HAL call.
            cleanup(valueToClean)
        }
        if notifyLateCleanup {
            onLateCleanupFinished()
        }
        continuationToResume?.resume(with: result)
    }
}

@available(macOS 14.2, *)
private final class CaptureSession {
    let destination: URL
    let metrics: CaptureMetrics

    var writerError: String? {
        writer.snapshot().errorDescription
    }

    private let streamFormat: StreamFormat
    private let ring: AudioRingBuffer
    private let writer: PCMWriter
    private let context: CaptureCallbackContext

    private var processObjectID: AudioObjectID = kAudioObjectUnknown
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var contextOpaque: UnsafeMutableRawPointer?
    private var started = false
    private var stopped = false

    init(pid: pid_t, destination: URL) throws {
        self.destination = destination
        guard pid > 0 else {
            throw AudioCaptureError.invalidProcessID
        }
        guard Self.isSupportedDestination(destination) else {
            throw AudioCaptureError.invalidDestination(destination)
        }

        processObjectID = try Self.processObjectID(for: pid)

        // Apple exposes this initializer specifically for a process list. It
        // creates a stereo mixdown while retaining the two-channel output,
        // unlike an empty CATapDescription whose default stream is not useful
        // as an aggregate input on all supported macOS releases.
        let tapUUID = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.isPrivate = true
        description.name = "ResonanceApp Process Tap"
        description.uuid = tapUUID

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTapID)
        NSLog(
            "[ResonanceApp.AudioCapture] create process tap pid=%d processObjectID=%u status=%d tapID=%u uuid=%@",
            pid,
            processObjectID,
            tapStatus,
            createdTapID,
            tapUUID.uuidString
        )
        guard tapStatus == noErr else {
            throw AudioCaptureError.tapCreation(tapStatus)
        }
        guard createdTapID != kAudioObjectUnknown, createdTapID != 0 else {
            throw AudioCaptureError.invalidTapID
        }
        tapID = createdTapID

        do {
            // CATapDescription.uuid is the tap UID assigned at creation. Use
            // the explicit UUID here rather than querying an unregistered tap
            // object, which can return '!obj' on affected macOS builds.
            let tapUID = tapUUID.uuidString
            var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateUID = "com.resonance.capture.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Resonance Capture \(UUID().uuidString.prefix(8))",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 0
                ]],
                // Do not wait for a physical output device. The tap itself is
                // the input source and the aggregate remains private.
                kAudioAggregateDeviceTapAutoStartKey: 1
            ]
            NSLog(
                "[ResonanceApp.AudioCapture] create aggregate uid=%@ tapID=%u tapUID=%@",
                aggregateUID,
                createdTapID,
                tapUID
            )
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &createdAggregateID
            )
            NSLog(
                "[ResonanceApp.AudioCapture] create aggregate status=%d aggregateID=%u",
                aggregateStatus,
                createdAggregateID
            )
            guard aggregateStatus == noErr else {
                throw AudioCaptureError.aggregateCreation(aggregateStatus)
            }
            aggregateDeviceID = createdAggregateID

            streamFormat = try Self.streamFormat(for: createdAggregateID)
            ring = AudioRingBuffer(
                capacityFrames: Self.ringCapacity(sampleRate: streamFormat.sampleRate),
                bufferCount: streamFormat.bufferCount,
                bytesPerFrame: streamFormat.bytesPerBufferFrame
            )
            metrics = CaptureMetrics(streamFormat: streamFormat)
            context = CaptureCallbackContext(ring: ring, metrics: metrics, streamFormat: streamFormat)
            writer = try PCMWriter(destination: destination, streamFormat: streamFormat, ring: ring, metrics: metrics)
        } catch {
            Self.destroyAggregate(&aggregateDeviceID)
            Self.destroyTap(&tapID)
            throw error
        }
    }

    deinit {
        context.stopAccepting()
        stopHardware()
        _ = writer.stopAndDrain()
        Self.destroyAggregate(&aggregateDeviceID)
        Self.destroyTap(&tapID)
        releaseContextOpaque()
    }

    func start() throws {
        guard !started, !stopped else { return }

        contextOpaque = Unmanaged.passRetained(context).toOpaque()
        var createdIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            resonanceAudioIOProc,
            contextOpaque,
            &createdIOProcID
        )
        guard ioStatus == noErr, let createdIOProcID else {
            releaseContextOpaque()
            throw AudioCaptureError.ioProcCreation(ioStatus)
        }
        ioProcID = createdIOProcID

        do {
            try writer.start()
            let startStatus = AudioDeviceStart(aggregateDeviceID, createdIOProcID)
            guard startStatus == noErr else {
                throw AudioCaptureError.deviceStart(startStatus)
            }
            started = true
        } catch {
            stopHardware()
            _ = writer.stopAndDrain()
            throw error
        }
    }

    func stop() -> CaptureSummary {
        guard !stopped else {
            return makeSummary()
        }

        context.stopAccepting()
        stopHardware()
        let writerSnapshot = writer.stopAndDrain()

        // The IOProc and aggregate must be gone before the tap. This also
        // guarantees that no callback can dereference contextOpaque after it
        // is released below.
        Self.destroyAggregate(&aggregateDeviceID)
        Self.destroyTap(&tapID)
        releaseContextOpaque()
        stopped = true

        return makeSummary(writerSnapshot: writerSnapshot)
    }

    private func stopHardware() {
        if started, let ioProcID {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            started = false
        }
        if let ioProcID {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
    }

    private func releaseContextOpaque() {
        guard let contextOpaque else { return }
        Unmanaged<CaptureCallbackContext>.fromOpaque(contextOpaque).release()
        self.contextOpaque = nil
    }

    private func makeSummary(writerSnapshot: PCMWriter.Snapshot? = nil) -> CaptureSummary {
        let metricSnapshot = metrics.snapshot()
        let writerSnapshot = writerSnapshot ?? writer.snapshot()
        return CaptureSummary(
            destination: destination,
            sampleRate: streamFormat.sampleRate,
            channelCount: streamFormat.channelCount,
            isInterleaved: streamFormat.isInterleaved,
            formatID: streamFormat.formatID,
            capturedFrames: Int64(writerSnapshot.writtenFrames),
            droppedFrames: ring.snapshot().droppedFrames,
            zeroDataFrames: metricSnapshot.zeroDataFrames,
            callbackCount: ring.snapshot().callbackCount,
            formatMismatchFrames: ring.snapshot().formatMismatchFrames,
            duration: streamFormat.sampleRate > 0
                ? Double(writerSnapshot.writtenFrames) / streamFormat.sampleRate
                : 0,
            peakLevel: metricSnapshot.peakLevel,
            writerError: writerSnapshot.errorDescription
        )
    }

    private static func isSupportedDestination(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "caf" || ext == "wav"
    }

    private static func ringCapacity(sampleRate: Double) -> Int {
        // Four seconds is enough to absorb a short file-writer stall while
        // keeping memory bounded. The upper limit prevents a pathological
        // high-rate tap from allocating an unbounded ring.
        let proposed = Int(max(1, sampleRate) * 4)
        return min(max(proposed, 2_048), 1_048_576)
    }

    private static func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        var qualifier = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            withUnsafeMutablePointer(to: &processObjectID) { outputPointer in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    UInt32(MemoryLayout<pid_t>.size),
                    qualifierPointer,
                    &dataSize,
                    outputPointer
                )
            }
        }
        guard status == noErr else {
            throw AudioCaptureError.processLookup(status)
        }
        guard processObjectID != kAudioObjectUnknown else {
            throw AudioCaptureError.processNotFound(pid)
        }
        return processObjectID
    }

    private static func streamFormat(for deviceID: AudioObjectID) throws -> StreamFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = withUnsafeMutablePointer(to: &asbd) { formatPointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                formatPointer
            )
        }
        guard status == noErr else {
            throw AudioCaptureError.streamFormat(status)
        }
        return try StreamFormat(asbd: asbd)
    }

    private static func destroyAggregate(_ id: inout AudioObjectID) {
        guard id != kAudioObjectUnknown else { return }
        _ = AudioHardwareDestroyAggregateDevice(id)
        id = kAudioObjectUnknown
    }

    private static func destroyTap(_ id: inout AudioObjectID) {
        guard id != kAudioObjectUnknown else { return }
        _ = AudioHardwareDestroyProcessTap(id)
        id = kAudioObjectUnknown
    }
}

@available(macOS 14.2, *)
private struct StreamFormat {
    let asbd: AudioStreamBasicDescription
    let avFormat: AVAudioFormat
    let sampleRate: Double
    let channelCount: Int
    let formatID: UInt32
    let isInterleaved: Bool
    let bufferCount: Int
    let bytesPerBufferFrame: Int
    let bytesPerSample: Int

    init(asbd: AudioStreamBasicDescription) throws {
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw AudioCaptureError.unsupportedAudioFormat("format ID \(asbd.mFormatID)")
        }
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw AudioCaptureError.unsupportedAudioFormat("invalid sample rate or channel count")
        }

        var mutableASBD = asbd
        guard let avFormat = AVAudioFormat(streamDescription: &mutableASBD) else {
            throw AudioCaptureError.unsupportedAudioFormat("AVAudioFormat could not represent the stream")
        }

        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let fallbackBytesPerSample = max(1, Int(asbd.mBitsPerChannel + 7) / 8)
        let bytesPerFrame = max(1, Int(asbd.mBytesPerFrame))
        let sampleBytes: Int
        if interleaved {
            sampleBytes = max(1, bytesPerFrame / channels)
        } else {
            sampleBytes = bytesPerFrame
        }

        self.asbd = asbd
        self.avFormat = avFormat
        self.sampleRate = asbd.mSampleRate
        self.channelCount = channels
        self.formatID = asbd.mFormatID
        self.isInterleaved = interleaved
        self.bufferCount = interleaved ? 1 : channels
        self.bytesPerBufferFrame = interleaved ? bytesPerFrame : max(bytesPerFrame, fallbackBytesPerSample)
        self.bytesPerSample = max(sampleBytes, fallbackBytesPerSample)
    }
}

@available(macOS 14.2, *)
private final class CaptureCallbackContext {
    let ring: AudioRingBuffer
    let metrics: CaptureMetrics
    let streamFormat: StreamFormat

    private var accepting: Int32 = 1

    init(ring: AudioRingBuffer, metrics: CaptureMetrics, streamFormat: StreamFormat) {
        self.ring = ring
        self.metrics = metrics
        self.streamFormat = streamFormat
    }

    func receive(_ inputData: UnsafePointer<AudioBufferList>) {
        guard OSAtomicAdd32Barrier(0, &accepting) != 0 else { return }
        ring.append(inputData)
    }

    func stopAccepting() {
        _ = OSAtomicCompareAndSwap32Barrier(1, 0, &accepting)
    }
}

@available(macOS 14.2, *)
private func resonanceAudioIOProc(
    _ device: AudioObjectID,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let context = Unmanaged<CaptureCallbackContext>.fromOpaque(clientData).takeUnretainedValue()
    context.receive(inputData)
    return noErr
}

@available(macOS 14.2, *)
final class AudioRingBuffer {
    struct Snapshot {
        let callbackCount: UInt64
        let droppedFrames: UInt64
        let formatMismatchFrames: UInt64
    }

    struct Chunk {
        let frameCount: Int
        let planes: [Data]
    }

    private let capacityFrames: Int
    private let bufferCount: Int
    private let bytesPerFrame: Int
    private var storage: [UnsafeMutableRawPointer]
    // The IOProc is the sole writer and the PCMWriter queue is the sole
    // reader. C11-style acquire/release ordering is provided by the Darwin
    // barrier primitives: publish write only after copying, and publish read
    // only after the consumer has copied data out.
    private var readCursor: Int64 = 0
    private var writeCursor: Int64 = 0
    private var callbackCountValue: Int64 = 0
    private var overflowFramesValue: Int64 = 0
    private var formatMismatchFramesValue: Int64 = 0

    init(capacityFrames: Int, bufferCount: Int, bytesPerFrame: Int) {
        self.capacityFrames = max(2_048, capacityFrames)
        self.bufferCount = max(1, bufferCount)
        self.bytesPerFrame = max(1, bytesPerFrame)
        self.storage = (0..<max(1, bufferCount)).map { _ in
            UnsafeMutableRawPointer.allocate(
                byteCount: max(2_048, capacityFrames) * max(1, bytesPerFrame),
                alignment: 64
            )
        }
    }

    deinit {
        for pointer in storage {
            pointer.deallocate()
        }
    }

    func append(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard buffers.count == bufferCount else {
            let estimatedFrames = estimateFrameCount(buffers)
            OSAtomicIncrement64Barrier(&callbackCountValue)
            OSAtomicAdd64Barrier(Int64(estimatedFrames), &formatMismatchFramesValue)
            return
        }

        let frameCount = estimateFrameCount(buffers)
        guard frameCount > 0 else { return }

        let publishedWrite = OSAtomicAdd64Barrier(0, &writeCursor)
        let publishedRead = OSAtomicAdd64Barrier(0, &readCursor)
        let usedFrames = publishedWrite - publishedRead
        guard usedFrames >= 0,
              usedFrames <= Int64(capacityFrames),
              frameCount <= capacityFrames - Int(usedFrames) else {
            OSAtomicIncrement64Barrier(&callbackCountValue)
            OSAtomicAdd64Barrier(Int64(frameCount), &overflowFramesValue)
            return
        }

        for (index, buffer) in buffers.enumerated() {
            guard let source = buffer.mData else {
                OSAtomicIncrement64Barrier(&callbackCountValue)
                OSAtomicAdd64Barrier(Int64(frameCount), &overflowFramesValue)
                return
            }
            let byteCount = frameCount * bytesPerFrame
            let writeFrame = Int(publishedWrite % Int64(capacityFrames))
            let firstFrames = min(frameCount, capacityFrames - writeFrame)
            let firstBytes = firstFrames * bytesPerFrame
            let secondBytes = byteCount - firstBytes
            let destination = storage[index].advanced(by: writeFrame * bytesPerFrame)
            memcpy(destination, source, firstBytes)
            if secondBytes > 0 {
                memcpy(storage[index], source.advanced(by: firstBytes), secondBytes)
            }
        }

        OSAtomicIncrement64Barrier(&callbackCountValue)
        _ = OSAtomicAdd64Barrier(Int64(frameCount), &writeCursor)
    }

    func pop(maxFrames: Int) -> Chunk? {
        let publishedRead = OSAtomicAdd64Barrier(0, &readCursor)
        let publishedWrite = OSAtomicAdd64Barrier(0, &writeCursor)
        let availableFrames = publishedWrite - publishedRead
        guard availableFrames > 0 else { return nil }

        let frameCount = min(max(1, maxFrames), Int(availableFrames))
        let readFrame = Int(publishedRead % Int64(capacityFrames))
        let firstFrames = min(frameCount, capacityFrames - readFrame)
        let firstBytes = firstFrames * bytesPerFrame
        let secondBytes = frameCount * bytesPerFrame - firstBytes
        var planes: [Data] = []
        planes.reserveCapacity(bufferCount)

        for pointer in storage {
            var data = Data(count: frameCount * bytesPerFrame)
            data.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.baseAddress else { return }
                memcpy(destinationBase, pointer.advanced(by: readFrame * bytesPerFrame), firstBytes)
                if secondBytes > 0 {
                    memcpy(destinationBase.advanced(by: firstBytes), pointer, secondBytes)
                }
            }
            planes.append(data)
        }

        // Do not publish the read cursor until every plane has been copied;
        // otherwise the producer could overwrite storage still being read.
        _ = OSAtomicAdd64Barrier(Int64(frameCount), &readCursor)
        return Chunk(frameCount: frameCount, planes: planes)
    }

    func dropAll() {
        let publishedWrite = OSAtomicAdd64Barrier(0, &writeCursor)
        let publishedRead = OSAtomicAdd64Barrier(0, &readCursor)
        let pending = max(Int64(0), publishedWrite - publishedRead)
        if pending > 0 {
            OSAtomicAdd64Barrier(pending, &overflowFramesValue)
            _ = OSAtomicAdd64Barrier(pending, &readCursor)
        }
    }

    func snapshot() -> Snapshot {
        return Snapshot(
            callbackCount: UInt64(max(0, OSAtomicAdd64Barrier(0, &callbackCountValue))),
            droppedFrames: UInt64(max(0, OSAtomicAdd64Barrier(0, &overflowFramesValue))),
            formatMismatchFrames: UInt64(max(0, OSAtomicAdd64Barrier(0, &formatMismatchFramesValue)))
        )
    }

    private func estimateFrameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        var result = Int.max
        for buffer in buffers {
            guard buffer.mData != nil else { return 0 }
            result = min(result, Int(buffer.mDataByteSize) / bytesPerFrame)
        }
        return result == Int.max ? 0 : result
    }
}

@available(macOS 14.2, *)
private final class CaptureMetrics {
    struct Snapshot {
        let peakLevel: Float
        let zeroDataFrames: UInt64
    }

    private let streamFormat: StreamFormat
    private let lock = NSLock()
    private var peakLevelValue: Float = 0
    private var zeroDataFramesValue: UInt64 = 0

    init(streamFormat: StreamFormat) {
        self.streamFormat = streamFormat
    }

    func record(_ chunk: AudioRingBuffer.Chunk) {
        let frames = chunk.frameCount
        guard frames > 0 else { return }
        var zeroFrames: UInt64 = 0
        var peak: Float = 0

        for frame in 0..<frames {
            var frameIsZero = true
            for plane in chunk.planes {
                let frameOffset = frame * streamFormat.bytesPerBufferFrame
                let endOffset = min(frameOffset + streamFormat.bytesPerBufferFrame, plane.count)
                guard frameOffset < endOffset else { continue }
                plane.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else { return }
                    let bytes = base.advanced(by: frameOffset).assumingMemoryBound(to: UInt8.self)
                    for offset in 0..<(endOffset - frameOffset) {
                        if bytes[offset] != 0 {
                            frameIsZero = false
                            break
                        }
                    }
                }
            }
            if frameIsZero {
                zeroFrames &+= 1
            }
            peak = max(peak, samplePeak(chunk: chunk, frame: frame))
        }

        lock.lock()
        peakLevelValue = max(peakLevelValue, peak)
        zeroDataFramesValue &+= zeroFrames
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(peakLevel: peakLevelValue, zeroDataFrames: zeroDataFramesValue)
    }

    private func samplePeak(chunk: AudioRingBuffer.Chunk, frame: Int) -> Float {
        let flags = streamFormat.asbd.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
        guard isFloat || isSignedInteger else { return 0 }

        let channels = streamFormat.channelCount
        let sampleBytes = streamFormat.bytesPerSample
        let planeCount = chunk.planes.count
        var result: Float = 0

        for channel in 0..<channels {
            let planeIndex = streamFormat.isInterleaved ? 0 : min(channel, planeCount - 1)
            guard planeIndex >= 0, planeIndex < planeCount else { continue }
            let offset = streamFormat.isInterleaved
                ? frame * streamFormat.bytesPerBufferFrame + channel * sampleBytes
                : frame * streamFormat.bytesPerBufferFrame
            let data = chunk.planes[planeIndex]
            guard offset >= 0, offset + sampleBytes <= data.count else { continue }

            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress?.advanced(by: offset) else { return }
                if isFloat, sampleBytes >= 4 {
                    var bits: UInt32 = 0
                    memcpy(&bits, base, MemoryLayout<UInt32>.size)
                    let value = Float(bitPattern: bits)
                    if value.isFinite {
                        result = max(result, abs(value))
                    }
                } else if isSignedInteger, sampleBytes == 2 {
                    var value: Int16 = 0
                    memcpy(&value, base, MemoryLayout<Int16>.size)
                    result = max(result, abs(Float(value)) / Float(Int16.max))
                } else if isSignedInteger, sampleBytes >= 4 {
                    var value: Int32 = 0
                    memcpy(&value, base, MemoryLayout<Int32>.size)
                    result = max(result, abs(Float(value)) / Float(Int32.max))
                } else if isSignedInteger, sampleBytes == 1 {
                    var value: Int8 = 0
                    memcpy(&value, base, MemoryLayout<Int8>.size)
                    result = max(result, abs(Float(value)) / Float(Int8.max))
                }
            }
        }
        return result
    }
}

@available(macOS 14.2, *)
private final class PCMWriter {
    struct Snapshot {
        let writtenFrames: Int64
        let errorDescription: String?
    }

    private let queue = DispatchQueue(label: "com.resonance.audio-capture.writer", qos: .utility)
    private let streamFormat: StreamFormat
    private let ring: AudioRingBuffer
    private let metrics: CaptureMetrics
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var writtenFrames: Int64 = 0
    private var errorDescription: String?
    private var started = false

    init(destination: URL, streamFormat: StreamFormat, ring: AudioRingBuffer, metrics: CaptureMetrics) throws {
        self.streamFormat = streamFormat
        self.ring = ring
        self.metrics = metrics
        do {
            self.file = try AVAudioFile(
                forWriting: destination,
                settings: streamFormat.avFormat.settings,
                commonFormat: streamFormat.avFormat.commonFormat,
                interleaved: streamFormat.isInterleaved
            )
        } catch {
            throw AudioCaptureError.audioFile(error.localizedDescription)
        }
    }

    func start() throws {
        guard !started else { return }
        started = true
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        source.resume()
        timer = source
    }

    func stopAndDrain() -> Snapshot {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            drain()
            file = nil
            started = false
        }
        return snapshot()
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(writtenFrames: writtenFrames, errorDescription: errorDescription)
        }
    }

    private func drain() {
        guard errorDescription == nil, let file else { return }
        while let chunk = ring.pop(maxFrames: 16_384) {
            guard let pcmBuffer = makePCMBuffer(chunk) else {
                errorDescription = "The captured PCM could not be represented as an AVAudioPCMBuffer."
                ring.dropAll()
                return
            }
            do {
                try file.write(from: pcmBuffer)
                metrics.record(chunk)
                writtenFrames += Int64(chunk.frameCount)
            } catch {
                errorDescription = error.localizedDescription
                ring.dropAll()
                return
            }
        }
    }

    private func makePCMBuffer(_ chunk: AudioRingBuffer.Chunk) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: streamFormat.avFormat,
            frameCapacity: AVAudioFrameCount(chunk.frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)

        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destination.count == chunk.planes.count else { return nil }
        for (index, source) in chunk.planes.enumerated() {
            guard let target = destination[index].mData,
                  source.count <= Int(UInt32.max) else {
                return nil
            }
            source.withUnsafeBytes { sourceBuffer in
                guard let sourceBase = sourceBuffer.baseAddress else { return }
                memcpy(target, sourceBase, source.count)
            }
            destination[index].mDataByteSize = UInt32(source.count)
        }
        return buffer
    }
}

import Darwin
import Foundation

@available(macOS 14.2, *)
private final class ProbeResource {}

@available(macOS 14.2, *)
private final class ProbeResult<Value> {
    private let lock = NSLock()
    private var value: Value?
    private var error: Error?

    func store(value: Value) {
        lock.lock()
        self.value = value
        error = nil
        lock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        value = nil
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (value: Value?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (value, error)
    }
}

@available(macOS 14.2, *)
private final class ProbeLedger {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var cleanupQueueWasSetupQueue = false
    private let cleanupFinished = DispatchSemaphore(value: 0)

    func recordCleanup(onSetupQueue: Bool) {
        lock.lock()
        recordedEvents.append("cleanup")
        cleanupQueueWasSetupQueue = onSetupQueue
        lock.unlock()
        cleanupFinished.signal()
    }

    func recordLeaseRelease(onSetupQueue: Bool) {
        lock.lock()
        recordedEvents.append("lease")
        if !onSetupQueue {
            // The production callback hops back to MainActor. Keep the event
            // sequence as the ordering evidence and do not require its queue.
        }
        lock.unlock()
    }

    func waitForCleanup() -> Bool {
        cleanupFinished.wait(timeout: .now() + .seconds(2)) == .success
    }

    func snapshot() -> (events: [String], cleanupQueueWasSetupQueue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (recordedEvents, cleanupQueueWasSetupQueue)
    }
}

@available(macOS 14.2, *)
@main
private struct StartCancellationProbe {
    private static var waitTimeout: DispatchTime { .now() + .seconds(2) }

    static func main() async {
        let results = [
            verifyCancelBeforeComplete(),
            verifyCompleteBeforeCancel(),
            verifyRepeatedCancel(),
            verifyTimeoutRace()
        ]

        for result in results {
            print(result.message)
        }
        if results.contains(where: { !$0.passed }) {
            exit(EXIT_FAILURE)
        }
    }

    private static func verifyCancelBeforeComplete() -> (passed: Bool, message: String) {
        let setupQueue = DispatchQueue(label: "resonance.capture-cancel-probe.cancel")
        let queueKey = DispatchSpecificKey<String>()
        setupQueue.setSpecific(key: queueKey, value: "setup")
        let setupEntered = DispatchSemaphore(value: 0)
        let releaseSetup = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let ledger = ProbeLedger()
        let result = ProbeResult<ProbeResource>()
        let operation = CaptureStartStateMachine(
            setupQueue: setupQueue,
            timeout: .seconds(2),
            setup: {
                setupEntered.signal()
                releaseSetup.wait()
                return ProbeResource()
            },
            cleanup: { _ in
                ledger.recordCleanup(onSetupQueue: DispatchQueue.getSpecific(key: queueKey) == "setup")
            },
            onLateCleanupFinished: {
                ledger.recordLeaseRelease(onSetupQueue: DispatchQueue.getSpecific(key: queueKey) == "setup")
            }
        )

        launch(operation: operation, result: result, completed: completed)
        let setupStarted = wait(setupEntered)
        operation.cancel()
        let awaitReturned = wait(completed)
        let beforeSetupRelease = ledger.snapshot()
        releaseSetup.signal()
        let cleanupCompleted = ledger.waitForCleanup()
        let afterSetupRelease = ledger.snapshot()

        let resultSnapshot = result.snapshot()
        let passed = setupStarted
            && awaitReturned
            && matchesError(resultSnapshot.error, equalTo: .startCancelled)
            && beforeSetupRelease.events.isEmpty
            && cleanupCompleted
            && afterSetupRelease.events == ["cleanup", "lease"]
            && afterSetupRelease.cleanupQueueWasSetupQueue
        return (passed, passed
            ? "cancel-before-complete: PASS (await cancelled before setup release; cleanup then lease on setup queue)"
            : "cancel-before-complete: FAIL (result=\(describe(resultSnapshot.error)) events=\(afterSetupRelease.events))")
    }

    private static func verifyCompleteBeforeCancel() -> (passed: Bool, message: String) {
        let setupQueue = DispatchQueue(label: "resonance.capture-cancel-probe.complete")
        let completed = DispatchSemaphore(value: 0)
        let ledger = ProbeLedger()
        let result = ProbeResult<ProbeResource>()
        let operation = CaptureStartStateMachine(
            setupQueue: setupQueue,
            timeout: .seconds(2),
            setup: { ProbeResource() },
            cleanup: { _ in ledger.recordCleanup(onSetupQueue: true) },
            onLateCleanupFinished: { ledger.recordLeaseRelease(onSetupQueue: false) }
        )

        launch(operation: operation, result: result, completed: completed)
        let awaitReturned = wait(completed)
        operation.cancel()
        let snapshot = result.snapshot()
        let ledgerSnapshot = ledger.snapshot()
        let passed = awaitReturned
            && snapshot.value != nil
            && snapshot.error == nil
            && ledgerSnapshot.events.isEmpty
        return (passed, passed
            ? "complete-before-cancel: PASS (post-completion cancel was a no-op)"
            : "complete-before-cancel: FAIL (result=\(describe(snapshot.error)) events=\(ledgerSnapshot.events))")
    }

    private static func verifyRepeatedCancel() -> (passed: Bool, message: String) {
        let setupQueue = DispatchQueue(label: "resonance.capture-cancel-probe.repeat")
        let queueKey = DispatchSpecificKey<String>()
        setupQueue.setSpecific(key: queueKey, value: "setup")
        let setupEntered = DispatchSemaphore(value: 0)
        let releaseSetup = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let ledger = ProbeLedger()
        let result = ProbeResult<ProbeResource>()
        let operation = CaptureStartStateMachine(
            setupQueue: setupQueue,
            timeout: .seconds(2),
            setup: {
                setupEntered.signal()
                releaseSetup.wait()
                return ProbeResource()
            },
            cleanup: { _ in
                ledger.recordCleanup(onSetupQueue: DispatchQueue.getSpecific(key: queueKey) == "setup")
            },
            onLateCleanupFinished: {
                ledger.recordLeaseRelease(onSetupQueue: DispatchQueue.getSpecific(key: queueKey) == "setup")
            }
        )

        launch(operation: operation, result: result, completed: completed)
        let setupStarted = wait(setupEntered)
        operation.cancel()
        operation.cancel()
        let awaitReturned = wait(completed)
        releaseSetup.signal()
        let cleanupCompleted = ledger.waitForCleanup()
        operation.cancel()
        let snapshot = result.snapshot()
        let ledgerSnapshot = ledger.snapshot()
        let passed = setupStarted
            && awaitReturned
            && cleanupCompleted
            && matchesError(snapshot.error, equalTo: .startCancelled)
            && ledgerSnapshot.events == ["cleanup", "lease"]
            && ledgerSnapshot.cleanupQueueWasSetupQueue
        return (passed, passed
            ? "repeated-cancel: PASS (one cancellation, one cleanup, one lease release)"
            : "repeated-cancel: FAIL (result=\(describe(snapshot.error)) events=\(ledgerSnapshot.events))")
    }

    private static func verifyTimeoutRace() -> (passed: Bool, message: String) {
        let setupQueue = DispatchQueue(label: "resonance.capture-cancel-probe.timeout")
        let queueKey = DispatchSpecificKey<String>()
        setupQueue.setSpecific(key: queueKey, value: "setup")
        let setupEntered = DispatchSemaphore(value: 0)
        let releaseSetup = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let ledger = ProbeLedger()
        let result = ProbeResult<ProbeResource>()
        let operation = CaptureStartStateMachine(
            setupQueue: setupQueue,
            timeout: .milliseconds(50),
            setup: {
                setupEntered.signal()
                releaseSetup.wait()
                return ProbeResource()
            },
            cleanup: { _ in
                ledger.recordCleanup(onSetupQueue: DispatchQueue.getSpecific(key: queueKey) == "setup")
            },
            onLateCleanupFinished: {
                ledger.recordLeaseRelease(onSetupQueue: DispatchQueue.getSpecific(key: queueKey) == "setup")
            }
        )

        launch(operation: operation, result: result, completed: completed)
        let setupStarted = wait(setupEntered)
        let timeoutReturned = wait(completed)
        operation.cancel()
        let beforeSetupRelease = ledger.snapshot()
        releaseSetup.signal()
        let cleanupCompleted = ledger.waitForCleanup()
        let afterSetupRelease = ledger.snapshot()
        let snapshot = result.snapshot()
        let passed = setupStarted
            && timeoutReturned
            && matchesError(snapshot.error, equalTo: .startTimeout)
            && beforeSetupRelease.events.isEmpty
            && cleanupCompleted
            && afterSetupRelease.events == ["cleanup", "lease"]
            && afterSetupRelease.cleanupQueueWasSetupQueue
        return (passed, passed
            ? "timeout-race: PASS (timeout won; late result cleaned before lease release)"
            : "timeout-race: FAIL (result=\(describe(snapshot.error)) events=\(afterSetupRelease.events))")
    }

    private static func launch<Value>(
        operation: CaptureStartStateMachine<Value>,
        result: ProbeResult<Value>,
        completed: DispatchSemaphore
    ) {
        Task.detached {
            do {
                result.store(value: try await operation.run())
            } catch {
                result.store(error: error)
            }
            completed.signal()
        }
    }

    private static func wait(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: waitTimeout) == .success
    }

    private static func matchesError(_ error: Error?, equalTo expected: AudioCaptureError) -> Bool {
        (error as? AudioCaptureError) == expected
    }

    private static func describe(_ error: Error?) -> String {
        error.map { String(describing: $0) } ?? "none"
    }
}

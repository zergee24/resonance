import CoreAudio
import Darwin
import Foundation

@available(macOS 14.2, *)
@main
struct RingProbe {
    static func main() {
        let sequenceResult = verifyConcurrentSequence()
        let overflowResult = verifyOverflowAccounting()

        print("sequence: \(sequenceResult.message)")
        print("overflow: \(overflowResult.message)")
        if !sequenceResult.passed || !overflowResult.passed {
            exit(EXIT_FAILURE)
        }
    }

    private static func verifyConcurrentSequence() -> (passed: Bool, message: String) {
        let ring = AudioRingBuffer(capacityFrames: 1_048_576, bufferCount: 1, bytesPerFrame: 4)
        let totalFrames = 200_000
        let producerDone = DispatchSemaphore(value: 0)
        let producerQueue = DispatchQueue(label: "resonance.capture-probe.producer")
        let consumerQueue = DispatchQueue(label: "resonance.capture-probe.consumer")
        let completion = DispatchSemaphore(value: 0)

        var receivedFrames = 0
        var firstMismatch: (expected: Int32, actual: Int32)?

        consumerQueue.async {
            var expected: Int32 = 0
            var producerFinished = false
            while !producerFinished {
                if let chunk = ring.pop(maxFrames: 4_096) {
                    for value in values(from: chunk) {
                        if value != expected, firstMismatch == nil {
                            firstMismatch = (expected, value)
                        }
                        expected &+= 1
                        receivedFrames += 1
                    }
                } else if producerDone.wait(timeout: .now()) == .success {
                    producerFinished = true
                } else {
                    usleep(100)
                }
            }
            while let chunk = ring.pop(maxFrames: 4_096) {
                for value in values(from: chunk) {
                    if value != expected, firstMismatch == nil {
                        firstMismatch = (expected, value)
                    }
                    expected &+= 1
                    receivedFrames += 1
                }
            }
            completion.signal()
        }

        producerQueue.async {
            var nextValue: Int32 = 0
            var remaining = totalFrames
            while remaining > 0 {
                let frameCount = min(512, remaining)
                append(valuesStartingAt: nextValue, frameCount: frameCount, to: ring)
                nextValue &+= Int32(frameCount)
                remaining -= frameCount
                usleep(100)
            }
            producerDone.signal()
        }

        _ = completion.wait(timeout: .now() + .seconds(10))
        let snapshot = ring.snapshot()
        let passed = receivedFrames == totalFrames
            && firstMismatch == nil
            && snapshot.droppedFrames == 0
            && snapshot.formatMismatchFrames == 0
        let detail = "received=\(receivedFrames)/\(totalFrames) dropped=\(snapshot.droppedFrames) mismatch=\(snapshot.formatMismatchFrames)"
        return (passed, passed ? "PASS (\(detail))" : "FAIL (\(detail))")
    }

    private static func verifyOverflowAccounting() -> (passed: Bool, message: String) {
        let ring = AudioRingBuffer(capacityFrames: 2_048, bufferCount: 1, bytesPerFrame: 4)
        append(valuesStartingAt: 0, frameCount: 4_096, to: ring)
        let snapshot = ring.snapshot()
        let passed = snapshot.droppedFrames == 4_096 && snapshot.formatMismatchFrames == 0
        let detail = "reportedOverflow=\(snapshot.droppedFrames) expected=4096"
        return (passed, passed ? "PASS (\(detail))" : "FAIL (\(detail))")
    }

    private static func append(valuesStartingAt start: Int32, frameCount: Int, to ring: AudioRingBuffer) {
        let byteCount = frameCount * MemoryLayout<Int32>.size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<Int32>.alignment
        )
        defer { storage.deallocate() }

        for index in 0..<frameCount {
            storage.storeBytes(
                of: start &+ Int32(index),
                toByteOffset: index * MemoryLayout<Int32>.size,
                as: Int32.self
            )
        }

        let buffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteCount),
            mData: storage
        )
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        withUnsafePointer(to: &list) { input in
            ring.append(input)
        }
    }

    private static func values(from chunk: AudioRingBuffer.Chunk) -> [Int32] {
        guard let plane = chunk.planes.first else { return [] }
        var result: [Int32] = []
        result.reserveCapacity(chunk.frameCount)
        plane.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            for index in 0..<chunk.frameCount {
                var value: Int32 = 0
                memcpy(
                    &value,
                    base.advanced(by: index * MemoryLayout<Int32>.size),
                    MemoryLayout<Int32>.size
                )
                result.append(value)
            }
        }
        return result
    }
}

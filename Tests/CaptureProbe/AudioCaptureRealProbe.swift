import Darwin
import Foundation

@available(macOS 14.2, *)
@main
private struct AudioCaptureRealProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("result: FAIL (\(error.localizedDescription))\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count >= 2 else {
            throw ProbeError("usage: AudioCaptureRealProbe <tone-probe-executable>")
        }
        let toneExecutable = URL(fileURLWithPath: CommandLine.arguments[1])
        let child = Process()
        child.executableURL = toneExecutable
        child.arguments = ["--tone"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-audio-capture-\(UUID().uuidString).caf")
        let capture = await MainActor.run { AudioCapture() }
        print("target: synthetic-tone pid=\(child.processIdentifier)")
        print("destination: \(destination.path)")
        try await capture.start(pid: child.processIdentifier, destination: destination)
        print("start: status=recording")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        guard let summary = await capture.stop() else {
            throw ProbeError("capture stop returned no summary")
        }
        print("summary: frames=\(summary.capturedFrames) callbacks=\(summary.callbackCount) dropped=\(summary.droppedFrames) zeroFrames=\(summary.zeroDataFrames) peak=\(summary.peakLevel) writerError=\(summary.writerError ?? "none")")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        print("file: bytes=\(fileSize) hasAudioData=\(summary.hasAudioData)")
        defer { try? FileManager.default.removeItem(at: destination) }

        guard summary.writerError == nil else {
            throw ProbeError("writer reported: \(summary.writerError!)")
        }
        guard summary.capturedFrames > 0, summary.callbackCount > 0, summary.hasAudioData else {
            throw ProbeError("capture completed without non-zero audio evidence")
        }
        guard fileSize > 512 else {
            throw ProbeError("capture file is unexpectedly small: \(fileSize) bytes")
        }
        print("result: PASS (AudioCapture wrote a non-zero CAF from a real process tap)")
    }

    private struct ProbeError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

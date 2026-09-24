import AVFoundation
import Darwin

@available(macOS 14.2, *)
@main
private struct TonePlayer {
    static func main() {
        do {
            try playTone()
        } catch {
            fputs("tone player failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func playTone() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(format.sampleRate * 20)
              ),
              let channelData = buffer.floatChannelData else {
            throw ToneError("could not allocate synthetic PCM")
        }

        let frameCount = Int(format.sampleRate * 20)
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(format.channelCount) {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let phase = Double(frame) / format.sampleRate * 440.0 * 2.0 * Double.pi
                samples[frame] = Float(sin(phase) * 0.2)
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
        player.play()
        Thread.sleep(forTimeInterval: 15)
    }

    private struct ToneError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

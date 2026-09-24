import AVFoundation
import Foundation

/// Errors reported while copying a confirmed end window out of a captured file.
public enum CapturedAudioWindowError: Error, LocalizedError, Equatable {
    case sourceAndDestinationAreTheSame
    case invalidEndSeconds
    case endOutOfRange(requested: Double, duration: Double)
    case emptySource
    case invalidSourceFormat
    case endBeforeFirstFrame
    case cannotCreateOutputFormat
    case cannotCreateBuffer
    case missingPCMData
    case unexpectedEndOfFile

    public var errorDescription: String? {
        switch self {
        case .sourceAndDestinationAreTheSame:
            return "The source and destination audio files must be different."
        case .invalidEndSeconds:
            return "The end time must be a finite number greater than zero."
        case let .endOutOfRange(requested, duration):
            return "The end time \(requested) seconds is outside the source duration \(duration) seconds."
        case .emptySource:
            return "The source audio file contains no frames."
        case .invalidSourceFormat:
            return "The source audio file has an invalid sample rate or channel count."
        case .endBeforeFirstFrame:
            return "The end time is positive but does not include a complete audio frame."
        case .cannotCreateOutputFormat:
            return "A PCM output format could not be created for the source audio format."
        case .cannotCreateBuffer:
            return "A PCM audio buffer could not be allocated."
        case .missingPCMData:
            return "The source did not provide non-interleaved Float32 PCM data."
        case .unexpectedEndOfFile:
            return "The source ended before the requested frame window was read."
        }
    }
}

/// Copies the confirmed beginning of a captured recording into an independent
/// PCM CAF window without changing the source recording.
public enum CapturedAudioWindow {
    /// Metadata returned for the copied window.
    public struct Result: Equatable {
        public let durationSeconds: Double
        public let frameCount: Int64
        public let sampleRate: Double
        public let channelCount: Int
        /// Number of frames for which at least one channel sample is non-zero.
        /// No amplitude threshold is applied; a quiet but non-zero sample counts.
        public let nonzeroFrames: Int64

        public init(
            durationSeconds: Double,
            frameCount: Int64,
            sampleRate: Double,
            channelCount: Int,
            nonzeroFrames: Int64
        ) {
            self.durationSeconds = durationSeconds
            self.frameCount = frameCount
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.nonzeroFrames = nonzeroFrames
        }
    }

    /// Copies frames `[0, floor(endSeconds * sampleRate))` from `fileURL` to
    /// `to`. The source sample rate and channel count are retained, the source
    /// is never written, and only a bounded PCM buffer is held per iteration.
    ///
    /// The destination should use a `.caf` extension so AVFoundation writes an
    /// independent CAF container suitable for later analysis.
    public static func trim(fileURL: URL, to destinationURL: URL, endSeconds: Double) throws -> Result {
        let sourcePath = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let destinationPath = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard sourcePath != destinationPath else {
            throw CapturedAudioWindowError.sourceAndDestinationAreTheSame
        }

        guard endSeconds.isFinite, endSeconds > 0 else {
            throw CapturedAudioWindowError.invalidEndSeconds
        }

        let source = try AVAudioFile(
            forReading: fileURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let processingFormat = source.processingFormat
        let sampleRate = processingFormat.sampleRate
        let channelCount = Int(processingFormat.channelCount)
        let totalFrames = source.length

        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            throw CapturedAudioWindowError.invalidSourceFormat
        }
        guard totalFrames > 0 else {
            throw CapturedAudioWindowError.emptySource
        }

        let sourceDuration = Double(totalFrames) / sampleRate
        guard endSeconds <= sourceDuration else {
            throw CapturedAudioWindowError.endOutOfRange(
                requested: endSeconds,
                duration: sourceDuration
            )
        }

        let requestedFrameValue = floor(endSeconds * sampleRate)
        guard requestedFrameValue.isFinite,
              requestedFrameValue >= 1,
              requestedFrameValue <= Double(totalFrames),
              requestedFrameValue <= Double(Int64.max) else {
            throw CapturedAudioWindowError.endBeforeFirstFrame
        }
        let requestedFrames = Int64(requestedFrameValue)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: processingFormat.channelCount,
            interleaved: false
        ) else {
            throw CapturedAudioWindowError.cannotCreateOutputFormat
        }

        // AVAudioFile writes each supplied buffer as it arrives. The fixed
        // capacity keeps a long recording out of memory and also bounds the
        // amount of data retained while the destination is being encoded.
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let chunkCapacity: AVAudioFrameCount = 65_536
        var remainingFrames = requestedFrames
        var writtenFrames: Int64 = 0
        var nonzeroFrames: Int64 = 0

        while remainingFrames > 0 {
            let request = AVAudioFrameCount(
                min(Int64(chunkCapacity), remainingFrames)
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: request
            ) else {
                throw CapturedAudioWindowError.cannotCreateBuffer
            }

            try source.read(into: buffer, frameCount: request)
            let readFrames = Int64(buffer.frameLength)
            guard readFrames > 0, readFrames <= Int64(request) else {
                throw CapturedAudioWindowError.unexpectedEndOfFile
            }
            guard let channelData = buffer.floatChannelData else {
                throw CapturedAudioWindowError.missingPCMData
            }

            let framesToWrite = min(readFrames, remainingFrames)
            for frame in 0..<Int(framesToWrite) {
                var hasNonzeroSample = false
                for channel in 0..<channelCount {
                    if channelData[channel][frame] != 0 {
                        hasNonzeroSample = true
                        break
                    }
                }
                if hasNonzeroSample {
                    nonzeroFrames += 1
                }
            }

            // The request is bounded by `remainingFrames`, so a conforming
            // AVAudioFile should never return more frames than we will copy.
            // Keep this guard explicit in case a custom decoder violates that
            // contract; it prevents the result from exceeding its end point.
            if framesToWrite < readFrames {
                buffer.frameLength = AVAudioFrameCount(framesToWrite)
            }
            try output.write(from: buffer)

            writtenFrames += framesToWrite
            remainingFrames -= framesToWrite
            if readFrames < Int64(request), remainingFrames > 0 {
                throw CapturedAudioWindowError.unexpectedEndOfFile
            }
        }

        return Result(
            durationSeconds: Double(writtenFrames) / sampleRate,
            frameCount: writtenFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            nonzeroFrames: nonzeroFrames
        )
    }
}

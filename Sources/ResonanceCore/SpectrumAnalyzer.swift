import AVFoundation
import Accelerate
import Foundation

/// Computes a one-sided Hann-windowed power spectral density without resampling
/// the source audio. The public feature artifact keeps the source sample rate,
/// channel separation, frequency bins and every analyzed frame.
public struct SpectrumAnalyzer: Sendable {
    fileprivate struct FileStreamDescriptor {
        let sampleRate: Double
        let channelCount: Int
        let frequencyBinsHz: [Double]
        let durationSeconds: Double
        let format: AudioFormatMetadata
        let parameters: SpectrumAnalysisParameters
    }

    /// Read-only information used by recording analysis to decide whether a
    /// PCM segment can produce at least one native analysis window.  This is
    /// deliberately based on the same configuration calculation as `analyze`
    /// and does not decode or alter the source audio.
    public struct InputEligibility: Sendable, Equatable {
        public let sampleCount: Int64
        public let sampleRate: Double
        public let requiredFrameLength: Int

        public var hasSpectrumFrame: Bool {
            sampleCount >= Int64(requiredFrameLength)
        }

        public init(sampleCount: Int64, sampleRate: Double, requiredFrameLength: Int) {
            self.sampleCount = sampleCount
            self.sampleRate = sampleRate
            self.requiredFrameLength = requiredFrameLength
        }
    }

    public struct Configuration: Codable, Sendable, Equatable {
        public let frameDurationSeconds: Double
        public let hopFraction: Double
        public let minimumFrameLength: Int
        public let maximumFrameLength: Int

        public init(
            frameDurationSeconds: Double = 0.18,
            hopFraction: Double = 0.25,
            minimumFrameLength: Int = 256,
            maximumFrameLength: Int = 1 << 18
        ) {
            self.frameDurationSeconds = frameDurationSeconds
            self.hopFraction = hopFraction
            self.minimumFrameLength = minimumFrameLength
            self.maximumFrameLength = maximumFrameLength
        }

        fileprivate func parameters(sampleRate: Double) throws -> SpectrumAnalysisParameters {
            guard sampleRate.isFinite, sampleRate > 0,
                  frameDurationSeconds.isFinite, frameDurationSeconds > 0,
                  hopFraction.isFinite, hopFraction > 0, hopFraction <= 1,
                  minimumFrameLength >= 2,
                  maximumFrameLength >= minimumFrameLength else {
                throw ResonanceCoreError.invalidAnalysisParameters
            }

            let requestedLength = frameDurationSeconds * sampleRate
            guard requestedLength.isFinite, requestedLength >= 2 else {
                throw ResonanceCoreError.invalidAnalysisParameters
            }
            let frameLength = nearestPowerOfTwo(
                Int(requestedLength.rounded()),
                minimum: minimumFrameLength,
                maximum: maximumFrameLength
            )
            let hopLength = max(1, Int((Double(frameLength) * hopFraction).rounded()))
            return SpectrumAnalysisParameters(
                frameLength: frameLength,
                hopLength: hopLength,
                window: "hann",
                oneSidedPSD: true,
                frameDurationSeconds: Double(frameLength) / sampleRate
            )
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Reads only the audio container metadata needed for the minimum-frame
    /// decision. It intentionally throws for empty or malformed audio so a
    /// corrupt file is not mislabeled as an ordinary short segment.
    public func inputEligibility(fileURL: URL) throws -> InputEligibility {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = format.channelCount
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            throw ResonanceCoreError.invalidAudioFormat
        }
        guard file.length > 0 else {
            throw ResonanceCoreError.emptyAudio
        }
        let parameters = try configuration.parameters(sampleRate: sampleRate)
        return InputEligibility(
            sampleCount: Int64(file.length),
            sampleRate: sampleRate,
            requiredFrameLength: parameters.frameLength
        )
    }

    /// Decodes a local audio file through AVAudioFile using the source sample
    /// rate and channel count. Decoding changes the sample representation to
    /// non-interleaved Float32 only; it does not downmix or resample.
    public func analyze(
        fileURL: URL,
        coverage: Coverage = .unknown,
        recordingID: UUID? = nil
    ) throws -> SpectrumFeatures {
        var frames: [SpectrumFrame] = []
        let stream = try streamFileFrames(
            fileURL: fileURL,
            onStart: { _ in },
            onFrame: { frames.append($0) }
        )
        return SpectrumFeatures(
            recordingID: recordingID,
            sampleRate: stream.sampleRate,
            channelCount: stream.channelCount,
            frequencyBinsHz: stream.frequencyBinsHz,
            frames: frames,
            durationSeconds: stream.durationSeconds,
            coverage: coverage,
            validMinHz: stream.frequencyBinsHz.first ?? 0,
            validMaxHz: stream.frequencyBinsHz.last ?? stream.sampleRate / 2,
            frequencyValidity: .mathematicalNyquist,
            format: stream.format,
            parameters: stream.parameters,
            analyzerVersion: "1-hann-psd"
        )
    }

    /// Decodes and aggregates a file one native FFT frame at a time. The
    /// native frame generator is shared with `analyze(fileURL:)`, so compact
    /// analysis does not first materialize a full-track native PSD artifact.
    public func analyzeCompact(
        fileURL: URL,
        coverage: Coverage = .unknown,
        recordingID: UUID? = nil,
        bandsPerOctave: Int = CompactSpectrum.defaultBandsPerOctave
    ) throws -> SpectrumFeatures {
        var accumulator: CompactSpectrum.Accumulator?
        let stream = try streamFileFrames(
            fileURL: fileURL,
            onStart: { descriptor in
                accumulator = try CompactSpectrum.Accumulator(
                    frequencyBinsHz: descriptor.frequencyBinsHz,
                    channelCount: descriptor.channelCount,
                    bandsPerOctave: bandsPerOctave
                )
            },
            onFrame: { frame in
                try accumulator?.append(frame)
            }
        )
        guard let accumulator else {
            throw CompactSpectrumError.invalidFrequencyGrid
        }
        return try accumulator.finish(
            recordingID: recordingID,
            sampleRate: stream.sampleRate,
            durationSeconds: stream.durationSeconds,
            coverage: coverage,
            validMinHz: stream.frequencyBinsHz.first ?? 0,
            validMaxHz: stream.frequencyBinsHz.last ?? stream.sampleRate / 2,
            frequencyValidity: .mathematicalNyquist,
            format: stream.format,
            parameters: stream.parameters,
            sourceAnalyzerVersion: "1-hann-psd"
        )
    }

    fileprivate func streamFileFrames(
        fileURL: URL,
        onStart: (FileStreamDescriptor) throws -> Void,
        onFrame: (SpectrumFrame) throws -> Void
    ) throws -> FileStreamDescriptor {
        // Keep file analysis bounded to one decoder block plus the overlap
        // needed by the next native FFT window. The caller owns only the
        // compact or native frames it explicitly chooses to retain.
        let file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let processingFormat = file.processingFormat
        let sampleRate = processingFormat.sampleRate
        let channelCount = Int(processingFormat.channelCount)
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            throw ResonanceCoreError.invalidAudioFormat
        }

        let parameters = try configuration.parameters(sampleRate: sampleRate)
        guard file.length > 0 else { throw ResonanceCoreError.emptyAudio }
        guard file.length <= Int64(Int.max) else { throw ResonanceCoreError.invalidAudioFormat }

        let context = try makeAnalysisContext(sampleRate: sampleRate, parameters: parameters)
        let descriptor = FileStreamDescriptor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frequencyBinsHz: context.frequencyBins,
            durationSeconds: 0,
            format: AudioFormatMetadata(
                sampleRate: sampleRate,
                channelCount: channelCount,
                sampleFormat: .float32,
                interleaved: false
            ),
            parameters: parameters
        )
        try onStart(descriptor)
        let chunkCapacity: AVAudioFrameCount = 65_536
        var remainingFrames = file.length
        var decodedFrameCount: Int64 = 0
        var bufferedStart = 0
        var nextFrameStart = 0
        var channels = Array(repeating: [Float](), count: channelCount)

        while remainingFrames > 0 {
            try Task.checkCancellation()
            var reachedShortRead = false
            try autoreleasepool {
                let requestedFrames = AVAudioFrameCount(min(Int64(chunkCapacity), remainingFrames))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: requestedFrames) else {
                    throw ResonanceCoreError.invalidAudioFormat
                }
                // Bound each request by the advertised file length. A short
                // final read is treated as the end of the readable container,
                // matching AVAudioFile's prior decode behavior.
                try file.read(into: buffer, frameCount: requestedFrames)
                let frameCount = Int(buffer.frameLength)
                if frameCount == 0 {
                    // Match the prior decoder's EOF behavior: a zero-frame
                    // read ends decoding, and the normal empty/no-frame
                    // checks below classify the accumulated samples.
                    reachedShortRead = true
                    return
                }
                guard let channelData = buffer.floatChannelData else {
                    throw ResonanceCoreError.unsupportedAudioFormat
                }
                for channel in 0..<channelCount {
                    let values = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
                    // Validate every decoded sample, including samples that
                    // remain in the final incomplete FFT window. Otherwise a
                    // NaN/Inf in the tail could be missed by frame processing.
                    guard values.allSatisfy({ $0.isFinite }) else {
                        throw ResonanceCoreError.nonFiniteAudioSample
                    }
                    channels[channel].append(contentsOf: values)
                }

                decodedFrameCount += Int64(frameCount)
                remainingFrames -= Int64(frameCount)
                reachedShortRead = frameCount < Int(requestedFrames)

                while decodedFrameCount - Int64(nextFrameStart) >= Int64(parameters.frameLength) {
                    try Task.checkCancellation()
                    let localFrameStart = nextFrameStart - bufferedStart
                    let frameChannels = channels.map {
                        Array($0[localFrameStart..<(localFrameStart + parameters.frameLength)])
                    }
                    try onFrame(makeSpectrumFrame(
                        channels: frameChannels,
                        sampleStart: 0,
                        timestampFrameStart: nextFrameStart,
                        sampleRate: sampleRate,
                        context: context
                    ))
                    nextFrameStart += parameters.hopLength

                    // Retain only the overlap/tail needed for the next frame.
                    // removeFirst keeps the working set bounded without making
                    // a second full-track copy during compaction.
                    let discardCount = nextFrameStart - bufferedStart
                    if discardCount >= Int(chunkCapacity) {
                        for channel in channels.indices {
                            channels[channel].removeFirst(discardCount)
                        }
                        bufferedStart = nextFrameStart
                    }
                }
            }
            if reachedShortRead {
                // Do not probe beyond a short final block.
                remainingFrames = 0
            }
        }

        guard decodedFrameCount > 0 else { throw ResonanceCoreError.emptyAudio }
        guard nextFrameStart > 0 else { throw ResonanceCoreError.noSpectrumFrames }

        return FileStreamDescriptor(
            sampleRate: descriptor.sampleRate,
            channelCount: descriptor.channelCount,
            frequencyBinsHz: descriptor.frequencyBinsHz,
            durationSeconds: Double(decodedFrameCount) / sampleRate,
            format: descriptor.format,
            parameters: descriptor.parameters
        )
    }

    /// Analyzes non-interleaved channels without changing their sample rate.
    /// This overload is useful for deterministic tests and for callers that
    /// already own a decoded PCM buffer.
    public func analyze(
        samples: [[Float]],
        sampleRate: Double,
        coverage: Coverage = .unknown,
        recordingID: UUID? = nil
    ) throws -> SpectrumFeatures {
        let format = AudioFormatMetadata(
            sampleRate: sampleRate,
            channelCount: samples.count,
            sampleFormat: .float32,
            interleaved: false
        )
        return try analyze(
            samples: samples,
            sampleRate: sampleRate,
            coverage: coverage,
            recordingID: recordingID,
            format: format
        )
    }

    private func analyze(
        samples: [[Float]],
        sampleRate: Double,
        coverage: Coverage,
        recordingID: UUID?,
        format: AudioFormatMetadata
    ) throws -> SpectrumFeatures {
        guard sampleRate.isFinite, sampleRate > 0,
              !samples.isEmpty,
              samples.allSatisfy({ !$0.isEmpty }) else {
            throw ResonanceCoreError.emptyAudio
        }
        guard let sampleCount = samples.first?.count,
              samples.allSatisfy({ $0.count == sampleCount }) else {
            throw ResonanceCoreError.inconsistentChannelLengths
        }
        guard samples.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw ResonanceCoreError.nonFiniteAudioSample
        }

        let parameters = try configuration.parameters(sampleRate: sampleRate)
        guard sampleCount >= parameters.frameLength else {
            throw ResonanceCoreError.noSpectrumFrames
        }

        let context = try makeAnalysisContext(sampleRate: sampleRate, parameters: parameters)
        var frames: [SpectrumFrame] = []
        frames.reserveCapacity(1 + (sampleCount - parameters.frameLength) / parameters.hopLength)

        var frameStart = 0
        while frameStart + parameters.frameLength <= sampleCount {
            try Task.checkCancellation()
            frames.append(makeSpectrumFrame(
                channels: samples,
                sampleStart: frameStart,
                timestampFrameStart: frameStart,
                sampleRate: sampleRate,
                context: context
            ))
            frameStart += parameters.hopLength
        }

        guard !frames.isEmpty else { throw ResonanceCoreError.noSpectrumFrames }

        let duration = Double(sampleCount) / sampleRate
        return SpectrumFeatures(
            recordingID: recordingID,
            sampleRate: sampleRate,
            channelCount: samples.count,
            frequencyBinsHz: context.frequencyBins,
            frames: frames,
            durationSeconds: duration,
            // An audio file's byte range does not prove its media coverage or
            // identity. Keep unknown as unknown so Matcher cannot award a
            // result until the caller supplies complete/partial coverage.
            coverage: coverage,
            validMinHz: context.frequencyBins.first ?? 0,
            validMaxHz: context.frequencyBins.last ?? sampleRate / 2,
            frequencyValidity: .mathematicalNyquist,
            format: format,
            parameters: parameters,
            analyzerVersion: "1-hann-psd"
        )
    }

    private struct AnalysisContext {
        let window: [Double]
        let windowPower: Double
        let binCount: Int
        let frequencyBins: [Double]
        let parameters: SpectrumAnalysisParameters
    }

    private func makeAnalysisContext(
        sampleRate: Double,
        parameters: SpectrumAnalysisParameters
    ) throws -> AnalysisContext {
        let window = hannWindow(length: parameters.frameLength)
        let windowPower = window.reduce(0.0) { $0 + $1 * $1 }
        guard windowPower.isFinite, windowPower > 0 else {
            throw ResonanceCoreError.invalidAnalysisParameters
        }
        let binCount = parameters.frameLength / 2 + 1
        let frequencyBins = (0..<binCount).map {
            Double($0) * sampleRate / Double(parameters.frameLength)
        }
        return AnalysisContext(
            window: window,
            windowPower: windowPower,
            binCount: binCount,
            frequencyBins: frequencyBins,
            parameters: parameters
        )
    }

    private func makeSpectrumFrame(
        channels: [[Float]],
        sampleStart: Int,
        timestampFrameStart: Int,
        sampleRate: Double,
        context: AnalysisContext
    ) -> SpectrumFrame {
        var channelPSDs: [[Double]] = []
        channelPSDs.reserveCapacity(channels.count)
        for channel in channels {
            var real = Array(repeating: 0.0, count: context.parameters.frameLength)
            for index in 0..<context.parameters.frameLength {
                let value = Double(channel[sampleStart + index])
                real[index] = value * context.window[index]
            }
            let (fftReal, fftImaginary) = acceleratedRealFFT(real)
            var psd = Array(repeating: 0.0, count: context.binCount)
            let denominator = sampleRate * context.windowPower
            for bin in 0..<context.binCount {
                let magnitudeSquared = fftReal[bin] * fftReal[bin] + fftImaginary[bin] * fftImaginary[bin]
                var value = magnitudeSquared / denominator
                if bin != 0 && bin != context.parameters.frameLength / 2 {
                    value *= 2.0
                }
                psd[bin] = value.isFinite && value >= 0 ? value : 0
            }
            channelPSDs.append(psd)
        }
        return SpectrumFrame(
            startTimeSeconds: Double(timestampFrameStart) / sampleRate,
            sampleCount: context.parameters.frameLength,
            powerSpectralDensityByChannel: channelPSDs
        )
    }
}

private func nearestPowerOfTwo(_ value: Int, minimum: Int, maximum: Int) -> Int {
    var powers: [Int] = []
    var candidate = 1
    while candidate <= maximum {
        if candidate >= minimum { powers.append(candidate) }
        if candidate > Int.max / 2 { break }
        candidate <<= 1
    }
    guard !powers.isEmpty else { return 2 }
    let eligible = powers.filter { $0 >= minimum }
    let candidates = eligible.isEmpty ? powers : eligible
    return candidates.min { abs($0 - value) < abs($1 - value) } ?? candidates[0]
}

private func hannWindow(length: Int) -> [Double] {
    guard length > 1 else { return [1] }
    let denominator = Double(length - 1)
    return (0..<length).map { index in
        0.5 - 0.5 * cos(2.0 * Double.pi * Double(index) / denominator)
    }
}

/// Uses Accelerate's native split-complex FFT. The private Swift fallback keeps
/// the analysis deterministic on platforms where the vector setup cannot be
/// created (for example, a stripped-down test runtime).
private func acceleratedRealFFT(_ input: [Double]) -> ([Double], [Double]) {
    let count = input.count
    precondition(count > 0 && count & (count - 1) == 0)
    var real = input
    var imaginary = Array(repeating: 0.0, count: count)

    let log2Length = vDSP_Length(log2(Double(count)))
    if let setup = vDSP_create_fftsetupD(log2Length, FFTRadix(kFFTRadix2)) {
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                guard let realBase = realBuffer.baseAddress,
                      let imaginaryBase = imaginaryBuffer.baseAddress else { return }
                var split = DSPDoubleSplitComplex(realp: realBase, imagp: imaginaryBase)
                vDSP_fft_zipD(setup, &split, 1, log2Length, FFTDirection(FFT_FORWARD))
            }
        }
        vDSP_destroy_fftsetupD(setup)
        return (
            Array(real.prefix(count / 2 + 1)),
            Array(imaginary.prefix(count / 2 + 1))
        )
    }

    return fallbackRealFFT(input)
}

private func fallbackRealFFT(_ input: [Double]) -> ([Double], [Double]) {
    let count = input.count
    var real = input
    var imaginary = Array(repeating: 0.0, count: count)

    var j = 0
    if count > 2 {
        for i in 1..<(count - 1) {
            var bit = count >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                real.swapAt(i, j)
            }
        }
    }

    var length = 2
    while length <= count {
        let angle = -2.0 * Double.pi / Double(length)
        let baseReal = cos(angle)
        let baseImaginary = sin(angle)
        var blockStart = 0
        while blockStart < count {
            var currentReal = 1.0
            var currentImaginary = 0.0
            let half = length / 2
            for offset in 0..<half {
                let even = blockStart + offset
                let odd = even + half
                let productReal = currentReal * real[odd] - currentImaginary * imaginary[odd]
                let productImaginary = currentReal * imaginary[odd] + currentImaginary * real[odd]
                let evenReal = real[even]
                let evenImaginary = imaginary[even]
                real[even] = evenReal + productReal
                imaginary[even] = evenImaginary + productImaginary
                real[odd] = evenReal - productReal
                imaginary[odd] = evenImaginary - productImaginary

                let nextReal = currentReal * baseReal - currentImaginary * baseImaginary
                currentImaginary = currentReal * baseImaginary + currentImaginary * baseReal
                currentReal = nextReal
            }
            blockStart += length
        }
        length <<= 1
    }

    return (
        Array(real.prefix(count / 2 + 1)),
        Array(imaginary.prefix(count / 2 + 1))
    )
}

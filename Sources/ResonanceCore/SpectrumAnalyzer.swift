import AVFoundation
import Accelerate
import Foundation

/// Computes a one-sided Hann-windowed power spectral density without resampling
/// the source audio. The public feature artifact keeps the source sample rate,
/// channel separation, frequency bins and every analyzed frame.
public struct SpectrumAnalyzer: Sendable {
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

    /// Decodes a local audio file through AVAudioFile using the source sample
    /// rate and channel count. Decoding changes the sample representation to
    /// non-interleaved Float32 only; it does not downmix or resample.
    public func analyze(
        fileURL: URL,
        coverage: Coverage = .unknown,
        recordingID: UUID? = nil
    ) throws -> SpectrumFeatures {
        let decoded = try decode(fileURL: fileURL)
        return try analyze(
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            coverage: coverage,
            recordingID: recordingID,
            format: decoded.format
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

        let window = hannWindow(length: parameters.frameLength)
        let windowPower = window.reduce(0.0) { $0 + $1 * $1 }
        guard windowPower.isFinite, windowPower > 0 else {
            throw ResonanceCoreError.invalidAnalysisParameters
        }

        let binCount = parameters.frameLength / 2 + 1
        let frequencyBins = (0..<binCount).map {
            Double($0) * sampleRate / Double(parameters.frameLength)
        }
        var frames: [SpectrumFrame] = []
        frames.reserveCapacity(1 + (sampleCount - parameters.frameLength) / parameters.hopLength)

        var frameStart = 0
        while frameStart + parameters.frameLength <= sampleCount {
            var channelPSDs: [[Double]] = []
            channelPSDs.reserveCapacity(samples.count)

            for channel in samples {
                var real = Array(repeating: 0.0, count: parameters.frameLength)
                for index in 0..<parameters.frameLength {
                    let value = Double(channel[frameStart + index])
                    real[index] = value * window[index]
                }
                let (fftReal, fftImaginary) = acceleratedRealFFT(real)
                var psd = Array(repeating: 0.0, count: binCount)
                let denominator = sampleRate * windowPower
                for bin in 0..<binCount {
                    let magnitudeSquared = fftReal[bin] * fftReal[bin] + fftImaginary[bin] * fftImaginary[bin]
                    var value = magnitudeSquared / denominator
                    if bin != 0 && bin != parameters.frameLength / 2 {
                        value *= 2.0
                    }
                    psd[bin] = value.isFinite && value >= 0 ? value : 0
                }
                channelPSDs.append(psd)
            }

            frames.append(
                SpectrumFrame(
                    startTimeSeconds: Double(frameStart) / sampleRate,
                    sampleCount: parameters.frameLength,
                    powerSpectralDensityByChannel: channelPSDs
                )
            )
            frameStart += parameters.hopLength
        }

        guard !frames.isEmpty else { throw ResonanceCoreError.noSpectrumFrames }

        let duration = Double(sampleCount) / sampleRate
        return SpectrumFeatures(
            recordingID: recordingID,
            sampleRate: sampleRate,
            channelCount: samples.count,
            frequencyBinsHz: frequencyBins,
            frames: frames,
            durationSeconds: duration,
            // An audio file's byte range does not prove its media coverage or
            // identity. Keep unknown as unknown so Matcher cannot award a
            // result until the caller supplies complete/partial coverage.
            coverage: coverage,
            validMinHz: frequencyBins.first ?? 0,
            validMaxHz: frequencyBins.last ?? sampleRate / 2,
            frequencyValidity: .mathematicalNyquist,
            format: format,
            parameters: parameters,
            analyzerVersion: "1-hann-psd"
        )
    }

    private struct DecodedAudio {
        let samples: [[Float]]
        let sampleRate: Double
        let format: AudioFormatMetadata
    }

    private func decode(fileURL: URL) throws -> DecodedAudio {
        // This initializer requests Float32/non-interleaved output while
        // keeping the file's native sample rate and channel count.
        let file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let processingFormat = file.processingFormat
        let sampleRate = processingFormat.sampleRate
        let channelCount = Int(processingFormat.channelCount)
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            throw ResonanceCoreError.invalidAudioFormat
        }

        var channels = Array(repeating: [Float](), count: channelCount)
        let chunkCapacity: AVAudioFrameCount = 65_536
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkCapacity) else {
                throw ResonanceCoreError.invalidAudioFormat
            }
            try file.read(into: buffer, frameCount: chunkCapacity)
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let channelData = buffer.floatChannelData else {
                throw ResonanceCoreError.unsupportedAudioFormat
            }
            for channel in 0..<channelCount {
                let values = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
                channels[channel].append(contentsOf: values)
            }
            if frameCount < Int(chunkCapacity) { break }
        }

        guard let firstCount = channels.first?.count, firstCount > 0,
              channels.allSatisfy({ $0.count == firstCount }) else {
            throw ResonanceCoreError.emptyAudio
        }
        return DecodedAudio(
            samples: channels,
            sampleRate: sampleRate,
            format: AudioFormatMetadata(
                sampleRate: sampleRate,
                channelCount: channelCount,
                sampleFormat: .float32,
                interleaved: false
            )
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

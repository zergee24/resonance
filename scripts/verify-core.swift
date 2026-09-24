import AVFoundation
import Foundation

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

@main
private struct CoreVerification {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        print("Core verification harness")
        print("root=\(root.path)")

        try verifyCurveImport(root: root)
        try verifySpectrumAndMatch()
        try verifyEnergyIntegration()
        try verifyExtendedBands()
        try verifyCAFDecode()
        try verifyWholeTimeline()

        print("PASS all core assertions")
    }

    private static func verifyWholeTimeline() throws {
        let sampleRate = 8_000.0
        let seconds = 60.0
        let tones = [500.0, 1_000.0, 2_000.0]
        let samples: [Float] = (0..<Int(seconds * sampleRate)).map { index in
            let part = min(2, index / Int(20 * sampleRate))
            return Float(sin(2 * .pi * tones[part] * Double(index) / sampleRate))
        }
        let features = try SpectrumAnalyzer().analyze(samples: [samples], sampleRate: sampleRate)
        try check(features.durationSeconds == seconds, "full timeline duration was truncated")
        try check((features.frames.last?.startTimeSeconds ?? 0) > 59, "analysis must reach the final second")
        let energies = tones.map { frequency in
            let indices = features.frequencyBinsHz.indices.filter { abs(features.frequencyBinsHz[$0] - frequency) < 40 }
            return features.frames.reduce(0.0) { total, frame in
                total + indices.reduce(0.0) { $0 + frame.powerSpectralDensityByChannel[0][$1] }
            }
        }
        let total = energies.reduce(0, +)
        try check(total > 0 && energies.allSatisfy { $0 / total > 0.30 && $0 / total < 0.37 },
                  "intro, middle and ending must all contribute to whole-recording features")
        print("PASS whole timeline: 60 seconds, intro/middle/ending energy all represented; no 30-second truncation")
    }

    private static func verifyCurveImport(root: URL) throws {
        let importer = CurveImporter()
        let sourceURL = root.appendingPathComponent("Samples/Raphael/Artipical_Raphael_HBB_R.csv")
        let raphael = try importer.load(
            from: sourceURL,
            name: "ARTPICAL Raphael",
            source: sourceURL.path,
            measurementSystem: "unknown"
        )
        try check(raphael.points.count == 480, "Raphael point count must be 480")
        try check(raphael.points.first?.frequencyHz == 19.5, "Raphael first frequency must be 19.5 Hz")
        try check(raphael.points.last?.frequencyHz == 20_000, "Raphael last frequency must be 20,000 Hz")
        print("PASS bundled Raphael sample: 480 points, 19.5–20,000 Hz")

        let parsed = try importer.parse(
            text: "FFT AudioTools v18.11\nFrequency\tdB\n100\t0\n1000\t10\noverall dB\t136.2 dB\n",
            name: "fixture",
            source: "fixture",
            measurementSystem: "fixture"
        )
        let interpolation = try require(parsed.value(at: 316.2277660168), "log-Hz interpolation returned nil")
        try check(parsed.points.count == 2, "AudioTools metadata must not be parsed as curve points")
        try check(abs(interpolation - 5) < 1e-8, "log-Hz interpolation must be 5 dB at sqrt(100*1000)")
        try check(parsed.value(at: 99) == nil, "curve interpolation must not extrapolate below range")
        do {
            _ = try importer.parse(
                text: "100,1\n100,2\n1000,2\n",
                name: "conflict",
                source: "fixture",
                measurementSystem: "fixture"
            )
            throw VerificationError.failed("conflicting duplicate frequency was accepted")
        } catch ResonanceCoreError.conflictingDuplicateFrequency {
            // Expected.
        }
        do {
            _ = try importer.parse(
                text: "100,NaN\n1000,2\n",
                name: "nonfinite",
                source: "fixture",
                measurementSystem: "fixture"
            )
            throw VerificationError.failed("non-finite curve value was accepted")
        } catch ResonanceCoreError.nonFiniteCurveValue {
            // Expected.
        }
        print("PASS curve validation: log interpolation, no extrapolation, duplicate/non-finite rejection")
    }

    private static func verifySpectrumAndMatch() throws {
        let sampleRate = 48_000.0
        let frameLength = 1_024
        let sampleCount = frameLength * 3
        let left = (0..<sampleCount).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / sampleRate)) }
        let right = (0..<sampleCount).map { Float(sin(2 * Double.pi * 12_000 * Double($0) / sampleRate)) }
        let coverage = try Coverage(
            kind: .complete,
            intervals: [try TimeRange(startSeconds: 0, endSeconds: Double(sampleCount) / sampleRate)],
            identityConfirmed: true
        )
        let analyzer = SpectrumAnalyzer(configuration: .init(
            frameDurationSeconds: Double(frameLength) / sampleRate,
            minimumFrameLength: frameLength,
            maximumFrameLength: frameLength
        ))
        let features = try analyzer.analyze(samples: [left, right], sampleRate: sampleRate, coverage: coverage)
        try check(features.sampleRate == sampleRate, "analyzer changed sample rate")
        try check(features.channelCount == 2, "analyzer downmixed stereo")
        try check(features.frames.count == 9, "unexpected STFT frame count")
        try check(features.frequencyBinsHz.last == sampleRate / 2, "frequency axis does not end at Nyquist")
        let leftPeak = try peakFrequency(features.frames[1].powerSpectralDensityByChannel[0], bins: features.frequencyBinsHz)
        let rightPeak = try peakFrequency(features.frames[1].powerSpectralDensityByChannel[1], bins: features.frequencyBinsHz)
        let binWidth = sampleRate / Double(frameLength)
        try check(abs(leftPeak - 1_000) <= binWidth, "left PSD peak is not near 1 kHz")
        try check(abs(rightPeak - 12_000) <= binWidth, "right PSD peak is not near 12 kHz")
        print("PASS Hann PSD: 48 kHz, stereo, 9 frames, left 1 kHz/right 12 kHz peaks")

        let reference = try makeCurve(
            name: "reference",
            frequencies: [20, 10_000, 20_000],
            values: [0, 0, 0],
            isReference: true
        )
        let flatCurve = try makeCurve(name: "flat", frequencies: [20, 20_000], values: [0, 0])
        let flatHeadphone = Headphone(name: "flat", owned: true, curve: flatCurve, referenceID: reference.id)
        let flatMatch = Matcher().match(features: features, headphone: flatHeadphone, reference: reference)
        try check(flatMatch.status == .evaluated, "complete coverage was not evaluated")
        let flatC = try require(flatMatch.c, "C missing for flat curve")
        let flatD = try require(flatMatch.d, "D missing for flat curve")
        try check(abs(flatC) < 1e-12, "flat curve C is not zero")
        try check(abs(flatD) < 1e-12, "flat curve D is not zero")

        let highCurve = try makeCurve(name: "high", frequencies: [20, 10_000, 20_000], values: [0, 4, 0])
        let highHeadphone = Headphone(name: "high", owned: true, curve: highCurve, referenceID: reference.id)
        let highMatch = Matcher().match(features: features, headphone: highHeadphone, reference: reference)
        try check(highMatch.dHigh != nil, "D_high should be available with 12 kHz content and full 10–20 kHz coverage")

        let missingReference = Matcher().match(features: features, headphone: flatHeadphone, reference: nil)
        try check(missingReference.status == .unevaluable && missingReference.unevaluableReason == .missingReference, "missing reference was evaluated")
        let unknownFeatures = try analyzer.analyze(samples: [left, right], sampleRate: sampleRate)
        let missingCoverage = Matcher().match(features: unknownFeatures, headphone: flatHeadphone, reference: reference)
        try check(missingCoverage.status == .unevaluable && missingCoverage.unevaluableReason == .missingCoverage, "unknown coverage was evaluated")
        let recordedOnly = try Coverage(kind: .partial, recordedDurationSeconds: 1)
        let recordedFeatures = replacingCoverage(features, with: recordedOnly)
        let recordedMatch = Matcher().match(features: recordedFeatures, headphone: flatHeadphone, reference: reference)
        try check(recordedOnly.isUsable && recordedMatch.status == .partial, "recorded-only partial coverage was not usable")
        let gapped = try Coverage(kind: .partial, recordedDurationSeconds: 1, hasUnexplainedGaps: true)
        let gappedMatch = Matcher().match(features: replacingCoverage(features, with: gapped), headphone: flatHeadphone, reference: reference)
        try check(!gapped.isUsable && gappedMatch.unevaluableReason == .missingCoverage, "gapped partial coverage was evaluated")
        let legacyJSON = Data("{\"kind\":\"partial\",\"mediaDurationSeconds\":null,\"intervals\":[],\"hasUnexplainedGaps\":false,\"identityConfirmed\":false}".utf8)
        let legacy = try JSONDecoder().decode(Coverage.self, from: legacyJSON)
        try check(legacy.recordedDurationSeconds == nil && !legacy.isUsable, "legacy coverage without recorded duration changed meaning")
        print("PASS C/D/D_high and guard conditions: flat C=D=0, high D_high available, recorded-only partial usable, gaps/unknown rejected")
    }

    private static func verifyEnergyIntegration() throws {
        let coverage = try Coverage(kind: .complete, intervals: [try TimeRange(startSeconds: 0, endSeconds: 1)])
        let bins = [20.0, 100.0, 200.0]
        let frame = SpectrumFrame(
            startTimeSeconds: 0,
            sampleCount: 1_024,
            powerSpectralDensityByChannel: [[1, 1, 1]]
        )
        let features = SpectrumFeatures(
            sampleRate: 48_000,
            channelCount: 1,
            frequencyBinsHz: bins,
            frames: [frame],
            durationSeconds: 1,
            coverage: coverage,
            validMinHz: 20,
            validMaxHz: 200,
            frequencyValidity: .measuredContent,
            format: AudioFormatMetadata(sampleRate: 48_000, channelCount: 1),
            parameters: SpectrumAnalysisParameters(frameLength: 1_024, hopLength: 256, frameDurationSeconds: 0.02)
        )
        let reference = try makeCurve(name: "reference", frequencies: [20, 200], values: [0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "flat", frequencies: [20, 200], values: [0, 0])
        let headphone = Headphone(name: "flat", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let result = Matcher().match(features: features, headphone: headphone, reference: reference)
        let firstBand = try require(result.frequencyBands.first?.inputEnergyFraction, "first band energy is missing")
        // FFT cells are [20,60], [60,150], [150,200]; the first 20–25 Hz
        // display band therefore receives 5/180 of the unit-PSD energy.
        try check(abs(firstBand - (5.0 / 180.0)) < 1e-12, "frequency-cell overlap integration is incorrect: \(firstBand)")
        try check(result.frequencyBands.first?.state == .insufficientResolution, "20–25 Hz band was not marked below FFT resolution")
        print("PASS frequency-cell integration: first 20–25 Hz share = 5/180; narrow band marked insufficient")
    }

    private static func verifyExtendedBands() throws {
        let coverage = try Coverage(kind: .complete, intervals: [try TimeRange(startSeconds: 0, endSeconds: 1)])
        let bins = [20.0, 10_000, 20_000, 22_000, 24_000]
        let frame = SpectrumFrame(startTimeSeconds: 0, sampleCount: 1_024, powerSpectralDensityByChannel: [[1, 1, 1, 1, 1]])
        let features = SpectrumFeatures(
            sampleRate: 96_000,
            channelCount: 1,
            frequencyBinsHz: bins,
            frames: [frame],
            durationSeconds: 1,
            coverage: coverage,
            validMinHz: 20,
            validMaxHz: 24_000,
            frequencyValidity: .mathematicalNyquist,
            format: AudioFormatMetadata(sampleRate: 96_000, channelCount: 1),
            parameters: SpectrumAnalysisParameters(frameLength: 16_384, hopLength: 4_096, frameDurationSeconds: 0.18)
        )
        let reference = try makeCurve(name: "reference", frequencies: [20, 20_000, 40_000], values: [0, 0, 0], isReference: true)
        let headphoneCurve = try makeCurve(name: "high", frequencies: [20, 20_000, 40_000], values: [0, 1, 2])
        let headphone = Headphone(name: "high", owned: true, curve: headphoneCurve, referenceID: reference.id)
        let result = Matcher().match(features: features, headphone: headphone, reference: reference)
        try check(result.frequencyBands.count == 31, "24 kHz detail should add one nominal >20 kHz band")
        let extended = try require(result.frequencyBands.last, "extended band evidence is missing")
        try check(extended.band.lowerHz == 20_000 && extended.band.upperHz == 25_000, "extended nominal band is not 20–25 kHz")
        try check(extended.actualUpperHz == 24_000, "partial 20–25 kHz coverage did not retain actual upper bound")
        try check(result.evaluatedMaxHz == 20_000, "C/D comparison range must remain 20 kHz")
        print("PASS extended bands: nominal 20–25 kHz, actual upper 24 kHz, C/D max 20 kHz")
    }

    private static func verifyCAFDecode() throws {
        let sampleRate = 44_100.0
        let frameCount = 9_000
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resonance-core-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw VerificationError.failed("could not create stereo CAF format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else {
            throw VerificationError.failed("could not create CAF buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount {
            channels[0][index] = Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate))
            channels[1][index] = Float(sin(2 * Double.pi * 2_000 * Double(index) / sampleRate))
        }
        try file.write(from: buffer)
        let coverage = try Coverage(
            kind: .complete,
            intervals: [try TimeRange(startSeconds: 0, endSeconds: Double(frameCount) / sampleRate)],
            identityConfirmed: true
        )
        let features = try SpectrumAnalyzer(configuration: .init(frameDurationSeconds: 0.05)).analyze(fileURL: url, coverage: coverage)
        try check(abs(features.sampleRate - sampleRate) < 1e-9, "CAF decoder changed sample rate")
        try check(features.channelCount == 2, "CAF decoder downmixed stereo")
        try check(features.coverage.kind == .complete, "CAF decode lost complete coverage")
        print("PASS CAF decode: 44.1 kHz and 2 channels preserved")
    }

    private static func makeCurve(name: String, frequencies: [Double], values: [Double], isReference: Bool = false) throws -> Curve {
        let points = try zip(frequencies, values).map { try CurvePoint(frequencyHz: $0.0, decibels: $0.1) }
        return try Curve(name: name, points: points, source: "verify-core", measurementSystem: "synthetic", isReference: isReference)
    }

    private static func replacingCoverage(_ features: SpectrumFeatures, with coverage: Coverage) -> SpectrumFeatures {
        SpectrumFeatures(
            recordingID: features.recordingID,
            sampleRate: features.sampleRate,
            channelCount: features.channelCount,
            frequencyBinsHz: features.frequencyBinsHz,
            frames: features.frames,
            durationSeconds: features.durationSeconds,
            coverage: coverage,
            validMinHz: features.validMinHz,
            validMaxHz: features.validMaxHz,
            frequencyValidity: features.frequencyValidity,
            format: features.format,
            parameters: features.parameters,
            analyzerVersion: features.analyzerVersion
        )
    }

    private static func peakFrequency(_ psd: [Double], bins: [Double]) throws -> Double {
        guard let index = psd.indices.max(by: { psd[$0] < psd[$1] }) else {
            throw VerificationError.failed("PSD has no bins")
        }
        return bins[index]
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw VerificationError.failed(message) }
        return value
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }
}

import Foundation
import AVFoundation

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

@main
private struct CompactSpectrumVerification {
    static func main() throws {
        let sampleRate = 48_000.0
        let frameLength = 8_192
        let frequencies = (0...(frameLength / 2)).map {
            Double($0) * sampleRate / Double(frameLength)
        }
        let duration = Double(frameLength) / sampleRate
        let left = frequencies.indices.map { Double($0 + 1) * 0.25 }
        let right = frequencies.indices.map { Double(frequencies.count - $0) * 0.1 }
        let coverage = try Coverage(
            kind: .complete,
            mediaDurationSeconds: duration,
            recordedDurationSeconds: duration,
            identityConfirmed: true
        )
        let native = SpectrumFeatures(
            sampleRate: sampleRate,
            channelCount: 2,
            frequencyBinsHz: frequencies,
            frames: [
                SpectrumFrame(startTimeSeconds: 0, sampleCount: 1_024, powerSpectralDensityByChannel: [left, right]),
                SpectrumFrame(startTimeSeconds: 0.25, sampleCount: 1_024, powerSpectralDensityByChannel: [left.map { $0 * 2 }, right.map { $0 * 0.5 }])
            ],
            durationSeconds: duration,
            coverage: coverage,
            validMinHz: 0,
            validMaxHz: sampleRate / 2,
            frequencyValidity: .mathematicalNyquist,
            format: AudioFormatMetadata(sampleRate: sampleRate, channelCount: 2),
            parameters: SpectrumAnalysisParameters(frameLength: frameLength, hopLength: 2_048, frameDurationSeconds: Double(frameLength) / sampleRate)
        )

        let compact = try CompactSpectrum.compact(native)
        try check(native.frequencyBinsHz.count == 4_097, "native fixture is not a 4097-bin 48 kHz/8192 grid")
        try check(compact.compactStorage?.bandsPerOctave == 48, "default compact grid is not 1/48 octave")
        try check(compact.compactStorage?.nativeBinCount == 4_097, "native bin provenance was lost")
        try check(compact.frequencyBinsHz.count < native.frequencyBinsHz.count / 4, "1/48 compact grid did not materially reduce native bins")
        try check(compact.frequencyBinsHz.count > 100, "compact fixture unexpectedly collapsed to an implausibly small grid")
        try check(compact.frequencyCellEdgesHz?.count == compact.frequencyBinsHz.count + 1, "explicit compact cell edges are missing")
        try check(compact.frames.count == native.frames.count, "compact frame count changed")
        try check(compact.frames.allSatisfy { $0.powerSpectralDensityByChannel.count == native.channelCount }, "compact channel count changed")
        try check(compact.frequencyBinsHz.allSatisfy(\.isFinite), "compact representative frequencies contain non-finite values")
        try check(zip(compact.frequencyBinsHz, compact.frequencyBinsHz.dropFirst()).allSatisfy { $0.0 < $0.1 }, "compact representative frequencies are not ordered")
        try checkBoundaryCells(native: native, compact: compact)

        let nativeEnergy = totalEnergy(native)
        let compactEnergy = totalEnergy(compact)
        try check(nativeEnergy.isFinite && compactEnergy.isFinite, "energy calculation is non-finite")
        try check(abs(nativeEnergy - compactEnergy) <= max(1e-12, abs(nativeEnergy) * 1e-12), "compact aggregation changed absolute frame power")

        let sameGrid = try CompactSpectrum.compact(compact)
        try check(sameGrid == compact, "same compact grid was compressed twice")
        do {
            _ = try CompactSpectrum.compact(compact, bandsPerOctave: 24)
            throw VerificationError.failed("different compact grids were treated as equivalent")
        } catch CompactSpectrumError.compactGridMismatch {
            // Expected: a compact grid is not silently reinterpreted.
        }

        let regions = compact.frequencyBinsHz.map(region)
        try check(!regions.contains(.audibleLow) || !regions.contains(.extended) || regions.firstIndex(of: .extended)! > regions.firstIndex(of: .audibleLow)!, "audible and extended groups are not ordered")
        try verifyInvalidCompactMetadata(compact)
        try verifyStreamingEntryPoint(coverage: coverage)
        print("PASS compact native-cell aggregation, explicit edges, channel/timeline preservation, absolute-energy conservation, and grid identity")
        print("native bins=\(native.frequencyBinsHz.count), compact bands=\(compact.frequencyBinsHz.count), native energy=\(nativeEnergy), compact energy=\(compactEnergy)")
    }

    private enum Region: Equatable {
        case dc
        case belowAudible
        case audibleLow
        case audibleHigh
        case extended
    }

    private static func region(_ frequency: Double) -> Region {
        if frequency == 0 { return .dc }
        if frequency < 20 { return .belowAudible }
        if frequency < 10_000 { return .audibleLow }
        if frequency < 20_000 { return .audibleHigh }
        return .extended
    }

    private static func totalEnergy(_ features: SpectrumFeatures) -> Double {
        let edges = features.frequencyCellEdgesHz ?? nativeEdges(features.frequencyBinsHz)
        return features.frames.reduce(0) { frameTotal, frame in
            frameTotal + frame.powerSpectralDensityByChannel.reduce(0) { channelTotal, channel in
                channelTotal + channel.enumerated().reduce(0) { total, item in
                    let width = edges[item.offset + 1] - edges[item.offset]
                    return total + max(0, item.element) * width
                }
            }
        }
    }

    private static func nativeEdges(_ frequencies: [Double]) -> [Double] {
        guard let first = frequencies.first, let last = frequencies.last else { return [] }
        var edges = [first]
        for index in 1..<frequencies.count {
            edges.append((frequencies[index - 1] + frequencies[index]) / 2)
        }
        edges.append(last)
        return edges
    }

    private static func checkBoundaryCells(native: SpectrumFeatures, compact: SpectrumFeatures) throws {
        guard let compactEdges = compact.frequencyCellEdgesHz else {
            throw VerificationError.failed("compact boundary probe has no explicit edges")
        }
        let nativeEdges = nativeEdges(native.frequencyBinsHz)
        for boundary in [20.0, 10_000.0, 20_000.0] {
            guard let nativeIndex = nativeEdges.indices.dropLast().first(where: {
                nativeEdges[$0] < boundary && boundary < nativeEdges[$0 + 1]
            }),
                  let compactIndex = compactEdges.indices.dropLast().first(where: {
                      compactEdges[$0] < boundary && boundary < compactEdges[$0 + 1]
                  }) else {
                throw VerificationError.failed("boundary \(boundary) Hz is not represented")
            }
            let nativeWidth = nativeEdges[nativeIndex + 1] - nativeEdges[nativeIndex]
            let compactWidth = compactEdges[compactIndex + 1] - compactEdges[compactIndex]
            try check(abs(nativeWidth - compactWidth) <= 1e-12, "boundary \(boundary) Hz native cell was grouped")
        }
        try check(Array(nativeEdges.suffix(2)) == Array(compactEdges.suffix(2)), "Nyquist cell was grouped or changed")
    }

    private static func verifyInvalidCompactMetadata(_ compact: SpectrumFeatures) throws {
        guard let edges = compact.frequencyCellEdgesHz,
              let storage = compact.compactStorage else {
            throw VerificationError.failed("compact fixture metadata is incomplete")
        }
        let unknownVersion = CompactSpectrumStorageMetadata(
            version: "compact-v999",
            bandsPerOctave: storage.bandsPerOctave,
            powerRepresentation: storage.powerRepresentation,
            quantizationErrorDescription: storage.quantizationErrorDescription,
            sourceAnalyzerVersion: storage.sourceAnalyzerVersion,
            nativeBinCount: storage.nativeBinCount
        )
        let unknown = replacing(compact, edges: edges, storage: unknownVersion)
        do {
            try CompactSpectrum.validate(unknown)
            throw VerificationError.failed("unknown compact metadata version was accepted")
        } catch CompactSpectrumError.invalidCompactMetadata {
            // Expected.
        }

        let reversed = replacing(compact, edges: Array(edges.reversed()), storage: storage)
        do {
            try CompactSpectrum.validate(reversed)
            throw VerificationError.failed("reversed compact cell edges were accepted")
        } catch CompactSpectrumError.invalidCompactMetadata {
            // Expected.
        }
    }

    private static func replacing(
        _ features: SpectrumFeatures,
        edges: [Double],
        storage: CompactSpectrumStorageMetadata
    ) -> SpectrumFeatures {
        SpectrumFeatures(
            recordingID: features.recordingID,
            sampleRate: features.sampleRate,
            channelCount: features.channelCount,
            frequencyBinsHz: features.frequencyBinsHz,
            frames: features.frames,
            durationSeconds: features.durationSeconds,
            coverage: features.coverage,
            validMinHz: features.validMinHz,
            validMaxHz: features.validMaxHz,
            frequencyValidity: features.frequencyValidity,
            format: features.format,
            parameters: features.parameters,
            analyzerVersion: features.analyzerVersion,
            frequencyCellEdgesHz: edges,
            compactStorage: storage
        )
    }

    private static func verifyStreamingEntryPoint(coverage: Coverage) throws {
        let sampleRate = 48_000.0
        let frameCount = 8_192
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-compact-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw VerificationError.failed("could not create compact stereo CAF format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else {
            throw VerificationError.failed("could not create compact CAF buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount {
            channels[0][index] = Float(0.2 * sin(2 * Double.pi * 440 * Double(index) / sampleRate))
            channels[1][index] = Float(0.15 * sin(2 * Double.pi * 3_200 * Double(index) / sampleRate))
        }
        try file.write(from: buffer)

        let analyzer = SpectrumAnalyzer()
        let native = try analyzer.analyze(fileURL: url, coverage: coverage)
        let fromArtifact = try CompactSpectrum.compact(native)
        let streamed = try analyzer.analyzeCompact(fileURL: url, coverage: coverage)
        try check(streamed == fromArtifact, "streaming compact entry point differs from legacy artifact compaction")
        try check(streamed.frames.count == native.frames.count, "streaming compact changed frame count")
        try check(streamed.channelCount == 2, "streaming compact changed stereo channel count")
        try check(streamed.coverage == coverage, "streaming compact changed coverage metadata")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError.failed(message) }
    }
}

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

private struct Options {
    var realAudioPath: String?
    var outputPath: String?
}

private struct ClassicSnapshot: Codable {
    let c: Double?
    let d: Double?
    let dHigh: Double?
    let evaluatedMinHz: Double?
    let evaluatedMaxHz: Double?
    let modelVersion: String
}

private struct MetricDelta: Codable {
    let c: Double?
    let d: Double?
    let dHigh: Double?
    let overallDB: Double?
    let p90DB: Double?
    let worstFrameTimeSeconds: Double?
}

private struct ClassicComparison: Codable {
    let referenceID: String
    let referenceName: String
    let native: ClassicSnapshot
    let compact: ClassicSnapshot
    let absoluteDifference: MetricDelta
}

private struct PersonalSnapshot: Codable {
    let referenceID: String
    let referenceName: String
    let overallDB: Double?
    let p90DB: Double?
    let worstFrameTimeSeconds: Double?
    let status: String
}

private struct PersonalComparison: Codable {
    let nativeModelVersion: String
    let compactModelVersion: String
    let nativeBestReferenceID: String?
    let compactBestReferenceID: String?
    let native: [PersonalSnapshot]
    let compact: [PersonalSnapshot]
    let absoluteDifferenceByReference: [MetricDelta]
}

private struct CompactEncodingReport: Codable {
    let encodedByteCount: Int
    let compressedByteCount: Int
    let nativeCompressedByteCount: Int
    let containsPackedUInt16: Bool
    let decodedFrameCount: Int
    let decodedBinCount: Int
    let compactStorageVersion: String?
    let bandsPerOctave: Int?
}

private struct RealAudioReport: Codable {
    let sourcePath: String
    let sampleRate: Double
    let channelCount: Int
    let durationSeconds: Double
    let frameCount: Int
    let nativeBinCount: Int
    let compactBinCount: Int
    let compactReductionFactor: Double
    let compactEncoding: CompactEncodingReport
    let classic: [ClassicComparison]
    let personal: PersonalComparison
    let limitations: [String]
}

@main
private struct CompactMatchingVerification {
    static func main() throws {
        let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
        let native = try makeSyntheticFeatures()
        let compact = try CompactSpectrum.compact(native, bandsPerOctave: 48)

        try check(compact.compactStorage?.version == CompactSpectrum.formatVersion, "compact metadata version missing")
        try check(compact.compactStorage?.bandsPerOctave == 48, "compact bands-per-octave metadata changed")
        try check(compact.frequencyCellEdgesHz?.count == compact.frequencyBinsHz.count + 1, "compact cell edge count mismatch")
        try check(compact.frequencyValidity == native.frequencyValidity, "compact changed frequency validity")
        try check(compact.validMaxHz == native.validMaxHz, "compact changed the input valid maximum")
        try check(native.frequencyCellEdgesHz == nil, "native fixture unexpectedly has compact cell edges")
        try check(compact.channelCount == native.channelCount, "compact changed channel count")

        try verifyExplicitEdges(compact)
        try verifyNarrowPeakGroup(native: native, compact: compact)
        try verifyIntegratedPower(native: native, compact: compact)
        try verifyMatcherResults(native: native, compact: compact)

        try check(compact.frequencyBinsHz.count < native.frequencyBinsHz.count / 4, "dense native fixture was not materially compacted")
        print("INFO dense grid nativeBins=\(native.frequencyBinsHz.count) compactBins=\(compact.frequencyBinsHz.count) reduction=\(String(format: "%.2fx", Double(native.frequencyBinsHz.count) / Double(compact.frequencyBinsHz.count)))")

        if let realAudioPath = options.realAudioPath {
            if let outputPath = options.outputPath {
                let sourceURL = URL(fileURLWithPath: realAudioPath).standardizedFileURL.resolvingSymlinksInPath()
                let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
                try check(sourceURL != outputURL, "--output must not overwrite the source CAF")
            }
            let report = try verifyRealAudio(audioPath: realAudioPath)
            try writeReport(report, outputPath: options.outputPath)
            print("WROTE real-audio JSON: \(options.outputPath ?? defaultOutputPath())")
        } else if options.outputPath != nil {
            throw VerificationError.failed("--output requires --real-audio")
        }

        print("PASS compact matching probe: power, explicit edges, stereo separation, 20 kHz bound, and finite score comparisons")
    }

    private static func parseOptions(_ args: [String]) throws -> Options {
        var realAudioPath: String?
        var outputPath: String?
        var index = 0
        while index < args.count {
            guard index + 1 < args.count else {
                throw VerificationError.failed("missing value after \(args[index])")
            }
            switch args[index] {
            case "--real-audio": realAudioPath = args[index + 1]
            case "--output": outputPath = args[index + 1]
            default: throw VerificationError.failed("unknown option \(args[index])")
            }
            index += 2
        }
        return Options(realAudioPath: realAudioPath, outputPath: outputPath)
    }

    private static func makeSyntheticFeatures() throws -> SpectrumFeatures {
        let sampleRate = 48_000.0
        let frameLength = 8_192
        let frequencyStep = sampleRate / Double(frameLength)
        let frequencies = (0...frameLength / 2).map { Double($0) * frequencyStep }
        let peakIndex = Int((12_000.0 / frequencyStep).rounded())
        let left = frequencies.enumerated().map { index, frequency in
            // One native FFT cell carries a narrow high-Q peak inside a
            // 1/48-octave group. Compact output must integrate this cell with
            // its neighbours and may therefore change curve-weighted scores.
            let peak = index == peakIndex ? 80.0 : 0.4 + 0.05 * sin(frequency / 700)
            return peak * (1 + Double(index % 5) * 0.03)
        }
        let right = frequencies.enumerated().map { index, frequency in
            let peak = index == peakIndex + 1 ? 11.0 : 0.8 + 0.08 * cos(frequency / 900)
            return peak * (1 + Double(index % 7) * 0.02)
        }
        let coverage = try Coverage(
            kind: .complete,
            intervals: [try TimeRange(startSeconds: 0, endSeconds: 1)],
            identityConfirmed: true
        )
        let frames = [
            SpectrumFrame(startTimeSeconds: 0, sampleCount: frameLength, powerSpectralDensityByChannel: [left, right]),
            SpectrumFrame(
                startTimeSeconds: 0.5,
                sampleCount: frameLength,
                powerSpectralDensityByChannel: [left.map { $0 * 0.8 }, right.map { $0 * 1.2 }]
            )
        ]
        return SpectrumFeatures(
            sampleRate: sampleRate,
            channelCount: 2,
            frequencyBinsHz: frequencies,
            frames: frames,
            durationSeconds: 1,
            coverage: coverage,
            validMinHz: 20,
            validMaxHz: sampleRate / 2,
            frequencyValidity: .measuredContent,
            format: AudioFormatMetadata(sampleRate: sampleRate, channelCount: 2),
            parameters: SpectrumAnalysisParameters(frameLength: frameLength, hopLength: frameLength / 4, frameDurationSeconds: Double(frameLength) / sampleRate),
            analyzerVersion: "synthetic-native"
        )
    }

    private static func verifyExplicitEdges(_ features: SpectrumFeatures) throws {
        guard let edges = features.frequencyCellEdgesHz else {
            throw VerificationError.failed("compact edges are missing")
        }
        try check(edges.allSatisfy(\.isFinite), "compact edges contain a non-finite value")
        try check(zip(edges, edges.dropFirst()).allSatisfy { $0.0 < $0.1 }, "compact edges are not strictly increasing")
        try check(features.frequencyBinsHz.indices.allSatisfy { index in
            edges[index] <= features.frequencyBinsHz[index] &&
                features.frequencyBinsHz[index] <= edges[index + 1]
        }, "compact cell edges do not contain their center frequencies")
    }

    private static func verifyIntegratedPower(native: SpectrumFeatures, compact: SpectrumFeatures) throws {
        guard let compactEdges = compact.frequencyCellEdgesHz else {
            throw VerificationError.failed("compact edges are unavailable for power verification")
        }
        let nativeEdges = midpointEdges(native.frequencyBinsHz)
        for frameIndex in native.frames.indices {
            for channelIndex in 0..<native.channelCount {
                let nativePower = zip(native.frames[frameIndex].powerSpectralDensityByChannel[channelIndex], nativeEdges.dropFirst())
                    .enumerated()
                    .reduce(0.0) { partial, item in
                        let index = item.offset
                        let width = item.element.1 - nativeEdges[index]
                        return partial + item.element.0 * width
                    }
                let compactPower = zip(compact.frames[frameIndex].powerSpectralDensityByChannel[channelIndex], compactEdges.dropFirst())
                    .enumerated()
                    .reduce(0.0) { partial, item in
                        let index = item.offset
                        let width = item.element.1 - compactEdges[index]
                        return partial + item.element.0 * width
                    }
                try check(nativePower.isFinite && compactPower.isFinite, "integrated power became non-finite")
                let scale = max(1, abs(nativePower))
                try check(abs(nativePower - compactPower) <= scale * 1e-10, "compact integrated power changed")
            }
        }
        try check(
            compact.frames[0].powerSpectralDensityByChannel[0] != compact.frames[0].powerSpectralDensityByChannel[1],
            "compact erased left/right channel separation"
        )
        try check(zip(native.frames, compact.frames).allSatisfy { nativeFrame, compactFrame in
            nativeFrame.startTimeSeconds == compactFrame.startTimeSeconds &&
                nativeFrame.sampleCount == compactFrame.sampleCount
        }, "compact changed frame timeline or sample counts")
        print("PASS integrated power and left/right channel retention")
    }

    private static func verifyNarrowPeakGroup(native: SpectrumFeatures, compact: SpectrumFeatures) throws {
        guard let edges = compact.frequencyCellEdgesHz,
              let compactIndex = compact.frequencyBinsHz.indices.first(where: { index in
                  edges[index] <= 12_000 && 12_000 <= edges[index + 1]
              }) else {
            throw VerificationError.failed("narrow peak compact group is missing")
        }
        let lower = edges[compactIndex]
        let upper = edges[compactIndex + 1]
        let nativeMembers = native.frequencyBinsHz.filter { $0 >= lower && $0 <= upper }
        try check(nativeMembers.count > 1, "narrow peak landed in a singleton compact group")
        print("INFO narrow-peak group \(String(format: "%.3f", lower))–\(String(format: "%.3f", upper)) Hz contains \(nativeMembers.count) native bins")
    }

    private static func verifyMatcherResults(native: SpectrumFeatures, compact: SpectrumFeatures) throws {
        let reference = try makeCurve(name: "flat reference", levelAt: { _ in 0 }, isReference: true)
        let headphone = Headphone(
            name: "synthetic stereo",
            owned: true,
            curve: try makeCurve(name: "left", levelAt: { frequency in
                let distance = abs(frequency - 12_000)
                if distance <= 250 { return 8.0 * (1.0 - distance / 250.0) }
                return frequency >= 20_000 ? -2.0 : 0.0
            }),
            rightCurve: try makeCurve(name: "right", levelAt: { frequency in
                frequency >= 20_000 ? 1.5 : -1.0
            }),
            referenceID: reference.id
        )
        let classic = Matcher().match(features: native, headphone: headphone, reference: reference)
        let compactClassic = Matcher().match(features: compact, headphone: headphone, reference: reference)
        try check(classic.isEvaluable && compactClassic.isEvaluable, "classic matcher did not evaluate native and compact fixtures")
        try check(classic.evaluatedMaxHz == 20_000 && compactClassic.evaluatedMaxHz == 20_000, "classic comparison range expanded beyond 20 kHz")
        try check(compactClassic.modelVersion.hasSuffix("-compact-v1"), "compact classic result did not identify its input representation")
        try check(compactClassic.message?.contains("高 Q 峰") == true, "compact classic limitation message is missing")
        try checkFinite(classic.c, "native C")
        try checkFinite(compactClassic.c, "compact C")
        try checkFinite(classic.d, "native D")
        try checkFinite(compactClassic.d, "compact D")
        try checkFinite(classic.dHigh, "native D_high")
        try checkFinite(compactClassic.dHigh, "compact D_high")

        let personal = PersonalMatcher(configuration: .init(includeSensitivityDiagnostics: false))
        let personalNative = personal.match(features: native, headphone: headphone, references: [reference])
        let personalCompact = personal.match(features: compact, headphone: headphone, references: [reference])
        try check(personalNative.modelVersion == PersonalMatcher.modelVersion, "native personal model version changed")
        try check(personalCompact.modelVersion.hasSuffix("-compact-v1"), "compact personal result did not identify its input representation")
        try check(personalNative.matches.first?.evaluatedMaxHz == 20_000, "native personal ranking range changed")
        try check(personalCompact.matches.first?.evaluatedMaxHz == 20_000, "compact personal ranking range expanded")
        try checkFinite(personalNative.matches.first?.overallDeviationDB, "native personal overall deviation")
        try checkFinite(personalCompact.matches.first?.overallDeviationDB, "compact personal overall deviation")
        try check(personalCompact.limitations.contains { $0.contains("高 Q 峰") }, "compact personal limitation is missing")

        let classicDDelta = abs((classic.d ?? .nan) - (compactClassic.d ?? .nan))
        let personalDelta = abs(
            (personalNative.matches.first?.overallDeviationDB ?? .nan) -
                (personalCompact.matches.first?.overallDeviationDB ?? .nan)
        )
        try check(classicDDelta.isFinite && personalDelta.isFinite, "native/compact score comparison is non-finite")
        print(String(format: "INFO narrow-peak native_vs_compact: C %.9g -> %.9g, D %.9g -> %.9g, D_high %.9g -> %.9g", classic.c ?? .nan, compactClassic.c ?? .nan, classic.d ?? .nan, compactClassic.d ?? .nan, classic.dHigh ?? .nan, compactClassic.dHigh ?? .nan))
        print(String(format: "INFO personal overall native_vs_compact: %.9g -> %.9g; absolute differences are reported, no equality claim", personalNative.matches.first?.overallDeviationDB ?? .nan, personalCompact.matches.first?.overallDeviationDB ?? .nan))
    }

    private static func verifyRealAudio(audioPath: String) throws -> RealAudioReport {
        let audioURL = URL(fileURLWithPath: audioPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw VerificationError.failed("real audio does not exist: \(audioURL.path)")
        }

        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let raphaelPath = rootURL.appendingPathComponent("Samples/Raphael/Artipical_Raphael_HBB_R.csv")
        let he1Path = rootURL.appendingPathComponent("Sources/ResonanceApp/Resources/Sennheiser_HE1_HuiHiFi.csv")
        let alterPath = rootURL.appendingPathComponent("Sources/ResonanceApp/Resources/MA_Audio_Alter_Ego_No_Dot_HuiHiFi.csv")
        let importer = CurveImporter()
        let raphael = try importer.load(
            from: raphaelPath,
            name: "Artipical Raphael · HBB",
            source: raphaelPath.path,
            measurementSystem: "HBB"
        )
        let he1 = try importer.load(
            from: he1Path,
            name: "Sennheiser HE1",
            source: he1Path.path,
            measurementSystem: "HuiHiFi",
            isReference: true
        )
        let alter = try importer.load(
            from: alterPath,
            name: "MA Audio ALTER EGO（无点）",
            source: alterPath.path,
            measurementSystem: "HuiHiFi",
            isReference: true
        )

        // The source CAF is only read by SpectrumAnalyzer. No feature or PCM
        // artifact is written beside it; compact and UInt16 round-trip data
        // stay in memory until the optional JSON report is emitted.
        let file = try AVAudioFile(forReading: audioURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        try check(duration > 0 && duration <= 45, "real probe is limited to a readable CAF of at most 45 seconds")
        let native = try SpectrumAnalyzer().analyze(fileURL: audioURL, coverage: .unknown, recordingID: UUID())
        let compact = try CompactSpectrum.compact(native, bandsPerOctave: 48)
        let (decodedCompact, encodedByteCount, compressedByteCount, containsPackedUInt16) = try encodeAndDecodeCompact(compact)
        let nativeCompressedByteCount = try autoreleasepool {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try (encoder.encode(native) as NSData).compressed(using: .lzfse).length
        }
        try check(containsPackedUInt16, "compact production payload did not contain packed UInt16 channels")
        try check(decodedCompact.compactStorage?.version == CompactSpectrum.formatVersion, "decoded compact metadata version missing")
        try check(decodedCompact.frequencyCellEdgesHz?.count == decodedCompact.frequencyBinsHz.count + 1, "decoded compact edges missing")

        let headphone = Headphone(
            name: raphael.name,
            owned: true,
            curve: raphael,
            referenceID: he1.id
        )
        let references = [he1, alter]
        let classicComparisons = references.map { reference in
            let nativeResult = Matcher().match(features: native, headphone: headphone, reference: reference)
            let compactResult = Matcher().match(features: decodedCompact, headphone: headphone, reference: reference)
            return ClassicComparison(
                referenceID: reference.id.uuidString,
                referenceName: reference.name,
                native: ClassicSnapshot(
                    c: nativeResult.c,
                    d: nativeResult.d,
                    dHigh: nativeResult.dHigh,
                    evaluatedMinHz: nativeResult.evaluatedMinHz,
                    evaluatedMaxHz: nativeResult.evaluatedMaxHz,
                    modelVersion: nativeResult.modelVersion
                ),
                compact: ClassicSnapshot(
                    c: compactResult.c,
                    d: compactResult.d,
                    dHigh: compactResult.dHigh,
                    evaluatedMinHz: compactResult.evaluatedMinHz,
                    evaluatedMaxHz: compactResult.evaluatedMaxHz,
                    modelVersion: compactResult.modelVersion
                ),
                absoluteDifference: MetricDelta(
                    c: absoluteDifference(nativeResult.c, compactResult.c),
                    d: absoluteDifference(nativeResult.d, compactResult.d),
                    dHigh: absoluteDifference(nativeResult.dHigh, compactResult.dHigh),
                    overallDB: nil,
                    p90DB: nil,
                    worstFrameTimeSeconds: nil
                )
            )
        }

        let personalMatcher = PersonalMatcher(configuration: .init(includeSensitivityDiagnostics: false))
        let nativePersonal = personalMatcher.match(features: native, headphone: headphone, references: references)
        let compactPersonal = personalMatcher.match(features: decodedCompact, headphone: headphone, references: references)
        let nativePersonalByID = Dictionary(uniqueKeysWithValues: nativePersonal.matches.map { ($0.referenceID, $0) })
        let compactPersonalByID = Dictionary(uniqueKeysWithValues: compactPersonal.matches.map { ($0.referenceID, $0) })
        let personalSnapshots = references.compactMap { reference -> (PersonalSnapshot, PersonalSnapshot, MetricDelta)? in
            guard let nativeMatch = nativePersonalByID[reference.id],
                  let compactMatch = compactPersonalByID[reference.id] else { return nil }
            return (
                PersonalSnapshot(
                    referenceID: reference.id.uuidString,
                    referenceName: reference.name,
                    overallDB: nativeMatch.overallDeviationDB,
                    p90DB: nativeMatch.frameErrorP90DB,
                    worstFrameTimeSeconds: nativeMatch.worstFrameStartTimeSeconds,
                    status: nativeMatch.status.rawValue
                ),
                PersonalSnapshot(
                    referenceID: reference.id.uuidString,
                    referenceName: reference.name,
                    overallDB: compactMatch.overallDeviationDB,
                    p90DB: compactMatch.frameErrorP90DB,
                    worstFrameTimeSeconds: compactMatch.worstFrameStartTimeSeconds,
                    status: compactMatch.status.rawValue
                ),
                MetricDelta(
                    c: nil,
                    d: nil,
                    dHigh: nil,
                    overallDB: absoluteDifference(nativeMatch.overallDeviationDB, compactMatch.overallDeviationDB),
                    p90DB: absoluteDifference(nativeMatch.frameErrorP90DB, compactMatch.frameErrorP90DB),
                    worstFrameTimeSeconds: absoluteDifference(nativeMatch.worstFrameStartTimeSeconds, compactMatch.worstFrameStartTimeSeconds)
                )
            )
        }

        var nativePersonalSnapshots: [PersonalSnapshot] = []
        var compactPersonalSnapshots: [PersonalSnapshot] = []
        var personalDeltas: [MetricDelta] = []
        for (nativeSnapshot, compactSnapshot, delta) in personalSnapshots {
            nativePersonalSnapshots.append(nativeSnapshot)
            compactPersonalSnapshots.append(compactSnapshot)
            personalDeltas.append(delta)
        }

        var limitations = [
            "native 与 compact 的差值仅针对本次 CAF、曲线和配置；不能外推为任意音频或任意未来曲线的数学等价保证。",
            "compact 曲线权重按 cell 中心频率近似；高 Q 峰、峰位与 20 kHz 边界可能改变。"
        ]
        for limitation in compactPersonal.limitations where !limitations.contains(limitation) {
            limitations.append(limitation)
        }
        for comparison in classicComparisons {
            if let message = Matcher().match(features: decodedCompact, headphone: headphone, reference: references.first(where: { $0.id.uuidString == comparison.referenceID })).message,
               !limitations.contains(message) {
                limitations.append(message)
            }
        }

        return RealAudioReport(
            sourcePath: audioURL.path,
            sampleRate: native.sampleRate,
            channelCount: native.channelCount,
            durationSeconds: native.durationSeconds,
            frameCount: native.frames.count,
            nativeBinCount: native.frequencyBinsHz.count,
            compactBinCount: decodedCompact.frequencyBinsHz.count,
            compactReductionFactor: Double(native.frequencyBinsHz.count) / Double(decodedCompact.frequencyBinsHz.count),
            compactEncoding: CompactEncodingReport(
                encodedByteCount: encodedByteCount,
                compressedByteCount: compressedByteCount,
                nativeCompressedByteCount: nativeCompressedByteCount,
                containsPackedUInt16: containsPackedUInt16,
                decodedFrameCount: decodedCompact.frames.count,
                decodedBinCount: decodedCompact.frequencyBinsHz.count,
                compactStorageVersion: decodedCompact.compactStorage?.version,
                bandsPerOctave: decodedCompact.compactStorage?.bandsPerOctave
            ),
            classic: classicComparisons,
            personal: PersonalComparison(
                nativeModelVersion: nativePersonal.modelVersion,
                compactModelVersion: compactPersonal.modelVersion,
                nativeBestReferenceID: nativePersonal.bestReferenceID?.uuidString,
                compactBestReferenceID: compactPersonal.bestReferenceID?.uuidString,
                native: nativePersonalSnapshots,
                compact: compactPersonalSnapshots,
                absoluteDifferenceByReference: personalDeltas
            ),
            limitations: limitations
        )
    }

    private static func encodeAndDecodeCompact(_ features: SpectrumFeatures) throws -> (SpectrumFeatures, Int, Int, Bool) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        encoder.userInfo[CodingUserInfoKey.resonanceCompactSpectrum] = true
        let data = try encoder.encode(features)
        let compressed = try (data as NSData).compressed(using: .lzfse)
        let decoded = try PropertyListDecoder().decode(SpectrumFeatures.self, from: compressed.decompressed(using: .lzfse) as Data)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return (decoded, data.count, compressed.length, containsKey("packedUInt16LE", in: propertyList))
    }

    private static func containsKey(_ key: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary[key] != nil { return true }
            return dictionary.values.contains { containsKey(key, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsKey(key, in: $0) }
        }
        return false
    }

    private static func writeReport(_ report: RealAudioReport, outputPath: String?) throws {
        let outputURL = URL(fileURLWithPath: outputPath ?? defaultOutputPath()).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: outputURL, options: .atomic)
    }

    private static func defaultOutputPath() -> String {
        "test-output/verification/compact-matching-real.json"
    }

    private static func absoluteDifference(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs, lhs.isFinite, rhs.isFinite else { return nil }
        let difference = abs(lhs - rhs)
        return difference.isFinite ? difference : nil
    }

    private static func makeCurve(
        name: String,
        levelAt: (Double) -> Double,
        isReference: Bool = false
    ) throws -> Curve {
        let frequencies: [Double] = [
            20, 1_000, 5_000, 9_000, 10_000, 11_500, 11_800, 12_000,
            12_200, 12_500, 15_000, 18_000, 19_500, 19_900, 20_000, 20_100,
            21_000, 24_000, 30_000, 40_000
        ]
        return try Curve(
            name: name,
            points: frequencies.map { try CurvePoint(frequencyHz: $0, decibels: levelAt($0)) },
            source: "synthetic-compact-matching",
            measurementSystem: "synthetic",
            validMinHz: 20,
            validMaxHz: 40_000,
            isReference: isReference
        )
    }

    private static func midpointEdges(_ frequencies: [Double]) -> [Double] {
        var edges = [frequencies[0]]
        edges.append(contentsOf: zip(frequencies, frequencies.dropFirst()).map { ($0.0 + $0.1) / 2 })
        edges.append(frequencies[frequencies.count - 1])
        return edges
    }

    private static func checkFinite(_ value: Double?, _ label: String) throws {
        try check(value?.isFinite == true, "\(label) is not finite")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError.failed(message) }
    }
}

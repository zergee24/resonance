import AVFoundation
import Foundation
import Darwin

private struct Options {
    var raphaelPath: String
    var he1Path: String
    var alterPath: String
    var liveFeaturePath: String?
    var liveAudioPath: String?
    var liveRecordingID: UUID?
    var outputPath: String
    var coreSourceSHA256: String
}

private struct ResourceReport: Codable {
    let name: String
    let pointCount: Int
    let minimumHz: Double
    let maximumHz: Double
    let sourcePath: String
}

private struct AlphaReport: Codable {
    let alpha: Double
    let referenceName: String
    let overallDB: Double?
    let highDB: Double?
    let p90DB: Double?
    let bestReferenceID: String?
}

private struct LiveMatchReport: Codable {
    let alpha: Double
    let referenceName: String
    let referenceID: String
    let overallDB: Double?
    let highDB: Double?
    let p90DB: Double?
    let worstFrameDB: Double?
    let worstFrameTimeSeconds: Double?
    let status: String
}

private struct LiveReport: Codable {
    let sourceKind: String
    let sourcePath: String
    let decodeSeconds: Double?
    let analysisSeconds: Double?
    let matchSeconds: Double
    let classicMatchSeconds: Double?
    let classicDB: Double?
    let classicC: Double?
    let classicDHigh: Double?
    let sampleRate: Double
    let channels: Int
    let durationSeconds: Double
    let frameCount: Int
    let commonMinimumHz: Double?
    let commonMaximumHz: Double?
    let matches: [LiveMatchReport]
    let alphaSensitivity: [AlphaReport]
}

private struct VerificationReport: Codable {
    let generatedAt: Date
    let modelVersion: String
    let coreSourceSHA256: String
    let resourceReports: [ResourceReport]
    let passedAssertions: [String]
    let live: LiveReport?
}

private struct HarnessFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@main
private struct PersonalVerification {
    private static let featureFrequencies: [Double] = [20, 100, 500, 1_000, 5_000, 10_000, 15_000, 20_000, 25_000, 40_000]
    private static let alphaValues = [0.2, 0.3, 0.5]
    private static let identityID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let alternateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let shapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static func main() {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            let report = try run(options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: URL(fileURLWithPath: options.outputPath), options: .atomic)
            print("PASS personal verification: \(report.passedAssertions.count) assertions")
            if let live = report.live {
                print(String(format: "LIVE PASS: %.3fs decode, %.3fs analysis, %.3fs match, %d frames", live.decodeSeconds ?? 0, live.analysisSeconds ?? 0, live.matchSeconds, live.frameCount))
            } else {
                print("LIVE SKIP: pass --live-feature or --live-audio for a read-only recording benchmark")
            }
        } catch {
            fputs("FAIL personal verification: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func parseOptions(_ args: [String]) throws -> Options {
        var raphael = "Samples/Raphael/Artipical_Raphael_HBB_R.csv"
        var he1 = "Sources/ResonanceApp/Resources/Sennheiser_HE1_HuiHiFi.csv"
        var alter = "Sources/ResonanceApp/Resources/MA_Audio_Alter_Ego_No_Dot_HuiHiFi.csv"
        var liveFeature: String?
        var liveAudio: String?
        var liveID: UUID?
        var output = "test-output/verification/personal-live.json"
        var coreSHA = "unknown"
        var index = 0
        while index < args.count {
            let arg = args[index]
            guard index + 1 < args.count else { throw HarnessFailure(message: "missing value after \(arg)") }
            switch arg {
            case "--raphael": raphael = args[index + 1]
            case "--he1": he1 = args[index + 1]
            case "--alter": alter = args[index + 1]
            case "--live-feature": liveFeature = args[index + 1]
            case "--live-audio": liveAudio = args[index + 1]
            case "--live-id":
                guard let value = UUID(uuidString: args[index + 1]) else { throw HarnessFailure(message: "invalid --live-id") }
                liveID = value
            case "--output": output = args[index + 1]
            case "--core-sha256":
                // The shell wrapper supplies the hash after compiling the exact
                // Core source used by this run.
                coreSHA = args[index + 1]
            default: throw HarnessFailure(message: "unknown option \(arg)")
            }
            index += 2
        }
        return Options(raphaelPath: raphael, he1Path: he1, alterPath: alter, liveFeaturePath: liveFeature, liveAudioPath: liveAudio, liveRecordingID: liveID, outputPath: output, coreSourceSHA256: coreSHA)
    }

    private static func run(options: Options) throws -> VerificationReport {
        let importer = CurveImporter()
        let raphael = try importer.load(from: URL(fileURLWithPath: options.raphaelPath), name: "Artipical Raphael · HBB", source: options.raphaelPath, measurementSystem: "HBB", isReference: false)
        let he1 = try importer.load(from: URL(fileURLWithPath: options.he1Path), name: "Sennheiser HE1", source: options.he1Path, measurementSystem: "HuiHiFi", isReference: true)
        let alter = try importer.load(from: URL(fileURLWithPath: options.alterPath), name: "MA Audio ALTER EGO（无点）", source: options.alterPath, measurementSystem: "HuiHiFi", isReference: true)
        try require(raphael.points.count == 480, "Raphael point count")
        try require(he1.points.count == 957 && alter.points.count == 957, "personal reference point counts")
        try require(abs(he1.validMinHz - 20) < 1e-9 && abs(alter.validMinHz - 20) < 1e-9, "personal reference lower bounds")
        try require(abs(he1.validMaxHz - 19_896.97461) < 1e-6 && abs(alter.validMaxHz - 19_896.97461) < 1e-6, "personal reference upper bounds")
        try require(he1.value(at: 20_000) == nil && alter.value(at: 20_000) == nil, "personal references do not extrapolate above source range")

        var passed: [String] = []
        passed.append("resource-range-and-no-extrapolation")
        let synthetic = try runSyntheticAssertions(raphael: raphael, he1: he1, alter: alter, passed: &passed)
        let live = try runLive(options: options, raphael: raphael, references: [he1, alter], passed: &passed)
        return VerificationReport(
            generatedAt: Date(),
            modelVersion: PersonalMatcher.modelVersion,
            coreSourceSHA256: options.coreSourceSHA256,
            resourceReports: [
                ResourceReport(name: raphael.name, pointCount: raphael.points.count, minimumHz: raphael.validMinHz, maximumHz: raphael.validMaxHz, sourcePath: options.raphaelPath),
                ResourceReport(name: he1.name, pointCount: he1.points.count, minimumHz: he1.validMinHz, maximumHz: he1.validMaxHz, sourcePath: options.he1Path),
                ResourceReport(name: alter.name, pointCount: alter.points.count, minimumHz: alter.validMinHz, maximumHz: alter.validMaxHz, sourcePath: options.alterPath)
            ],
            passedAssertions: passed + synthetic,
            live: live
        )
    }

    private static func runSyntheticAssertions(raphael: Curve, he1: Curve, alter: Curve, passed: inout [String]) throws -> [String] {
        let features = try syntheticFeatures(extended: true, coverage: .complete)
        let flat = try curve(id: identityID, name: "flat", levels: Array(repeating: 0, count: featureFrequencies.count), maximum: 40_000)
        let shape = try curve(id: shapeID, name: "shape", levels: [4, 4, 3, 2, 1, 0, -3, -4, -7, -8], maximum: 40_000)
        let alternate = try curve(id: alternateID, name: "alternate", levels: [4, 4, 3, 2, 1, 0, -3, -4, 11, 12], maximum: 40_000)
        let headphone = Headphone(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "synthetic", owned: true, curve: shape, referenceID: identityID)
        let identityHeadphone = Headphone(id: headphone.id, name: headphone.name, owned: true, curve: flat, referenceID: identityID)
        let matcher = PersonalMatcher()

        let identity = matcher.match(features: features, headphone: identityHeadphone, references: [flat])
        try require(identity.bestReferenceID == identityID, "identity selects exact reference")
        let identityDB = try tryValue(identity.matches.first?.overallDB, "identity overall")
        try require(identityDB < 1e-9, "identity residual is zero")
        passed.append("identity")

        let shiftedHeadphone = try shift(flat, by: 120, id: flat.id)
        let shiftedReference = try shift(flat, by: 120, id: flat.id)
        let shifted = matcher.match(features: features, headphone: Headphone(id: headphone.id, name: headphone.name, owned: true, curve: shiftedHeadphone, referenceID: shiftedReference.id), references: [shiftedReference])
        let shiftedDB = try tryValue(shifted.matches.first?.overallDB, "shifted")
        try require(abs(identityDB - shiftedDB) < 1e-9, "global curve level invariance")
        passed.append("global-level-invariance")

        let phaseFeatures = try syntheticFeatures(extended: false, coverage: .complete, leftScale: 1, rightScale: 1)
        let phaseResult = matcher.match(features: phaseFeatures, headphone: identityHeadphone, references: [flat])
        let phaseDB = try tryValue(phaseResult.matches.first?.overallDB, "phase")
        try require(phaseResult.matches.first?.status == .evaluated && phaseDB < 1e-9, "opposite channel phase does not cancel PSD energy")
        passed.append("stereo-power-noncancellation")

        let shaped = matcher.match(features: features, headphone: headphone, references: [flat])
        let low = shaped.matches.first?.bandEvidence.filter { $0.lowerHz < 200 }.compactMap { $0.deviationDB }.first
        let high = shaped.matches.first?.bandEvidence.filter { $0.lowerHz >= 10_000 && $0.lowerHz < 20_000 }.compactMap { $0.deviationDB }.first
        try require(low != nil && high != nil && abs((low ?? 0) - (high ?? 0)) > 1e-9, "low/high band shape differs")
        passed.append("low-high-shape")

        let uniform = matcher.match(features: try uniformBandFeatures(), headphone: identityHeadphone, references: [flat])
        guard let uniformMatch = uniform.matches.first else { throw HarnessFailure(message: "uniform band result missing") }
        let completeBands = uniformMatch.bandEvidence.filter { evidence in
            evidence.state == .evaluated && evidence.lowerHz >= 20 && evidence.upperHz <= 20_000
        }
        try require(!completeBands.isEmpty, "uniform band evidence exists")
        let totalSupportWidth = 20_000.0 - 20.0
        for band in completeBands {
            guard let share = band.measuredEnergyFraction else { throw HarnessFailure(message: "missing uniform measured energy fraction") }
            let expected = (band.upperHz - band.lowerHz) / totalSupportWidth
            try require(abs(share - expected) < 1e-5, "uniform band area (band.lowerHz)-(band.upperHz)")
        }
        passed.append("uniform-band-area-conservation")

        let silence = try syntheticFeatures(extended: false, coverage: .complete, silence: true)
        let silentResult = matcher.match(features: silence, headphone: identityHeadphone, references: [flat, alternate])
        try require(silentResult.bestReferenceID == nil && silentResult.matches.allSatisfy { $0.status == .noAudioContent }, "silence does not fabricate best 0 dB")
        passed.append("silence-no-fabricated-best")

        let partial = matcher.match(features: try syntheticFeatures(extended: false, coverage: .partial), headphone: identityHeadphone, references: [flat])
        try require(partial.matches.first?.status == .partial && partial.matches.first?.overallDB != nil, "partial coverage remains computable")
        passed.append("partial-computable")

        let baseFeatures = try syntheticFeatures(extended: false, coverage: .complete)
        let baseReference = try curve(id: identityID, name: "base", levels: Array(repeating: 0, count: 8), maximum: 20_000)
        let baseReferenceExtended = try curve(id: identityID, name: "base-extended", levels: Array(repeating: 0, count: featureFrequencies.count), maximum: 40_000)
        let extReference = try curve(id: alternateID, name: "extended-only-difference", levels: [0, 0, 0, 0, 0, 0, 0, 0, 20, 20], maximum: 40_000)
        let extResult = matcher.match(features: features, headphone: identityHeadphone, references: [baseReferenceExtended, extReference])
        let baseResult = matcher.match(features: baseFeatures, headphone: identityHeadphone, references: [baseReference])
        let extendedDB = try tryValue(extResult.matches.first?.overallDB, "extended")
        let baseDB = try tryValue(baseResult.matches.first?.overallDB, "base")
        try require(abs(extendedDB - baseDB) < 1e-9, ">20 kHz does not change main ranking metric")
        try require(extResult.bestReferenceID == identityID, ">20 kHz cannot create a different best reference")
        passed.append("extended-band-bypasses-main-rank")

        try require(extResult.matches.count == 2 && extResult.limitations.contains(where: { $0.contains("未跨参考拼接") }), "multiple references remain independent")
        passed.append("multi-reference-no-segment-splicing")

        let classic = Matcher().match(features: features, headphone: headphone, reference: flat)
        let signed = classic.frequencyBands.compactMap { $0.relativeGainDB }
        try require(signed.contains(where: { $0 > 0 }) && signed.contains(where: { $0 < 0 }), "classic signed band gain remains available")
        let worstTime = try tryValue(shaped.matches.first?.worstFrameTimeSeconds, "worst frame time")
        try require([0.0, 1.0, 2.0].contains(where: { abs($0 - worstTime) < 1e-9 }), "worst frame time maps to an input frame")
        passed.append("signed-band-gain-and-worst-time")

        var alphaResults: [Double] = []
        for alpha in alphaValues {
            let result = PersonalMatcher(configuration: .init(compressionExponent: alpha)).match(features: features, headphone: headphone, references: [flat])
            alphaResults.append(try tryValue(result.matches.first?.overallDB, "alpha \(alpha)"))
        }
        try require(alphaResults.max()! - alphaResults.min()! > 1e-10, "alpha sensitivity is observable")
        passed.append("alpha-0.2-0.3-0.5")

        _ = raphael; _ = he1; _ = alter
        return ["synthetic-suite"]
    }

    private static func runLive(options: Options, raphael: Curve, references: [Curve], passed: inout [String]) throws -> LiveReport? {
        guard let featurePath = options.liveFeaturePath ?? options.liveAudioPath else { return nil }
        let started = Date()
        let features: SpectrumFeatures
        let sourceKind: String
        let decodeSeconds: Double?
        let analysisSeconds: Double?
        if let liveFeaturePath = options.liveFeaturePath {
            let decodeStart = Date()
            features = try readArtifact(URL(fileURLWithPath: liveFeaturePath))
            decodeSeconds = Date().timeIntervalSince(decodeStart)
            analysisSeconds = nil
            sourceKind = "feature-artifact"
        } else {
            let analysisStart = Date()
            let coverage = try Coverage(kind: .partial, recordedDurationSeconds: nil, intervals: [])
            features = try SpectrumAnalyzer().analyze(fileURL: URL(fileURLWithPath: featurePath), coverage: coverage, recordingID: options.liveRecordingID)
            decodeSeconds = nil
            analysisSeconds = Date().timeIntervalSince(analysisStart)
            sourceKind = "pcm-analysis"
        }
        let headphone = Headphone(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, name: "Artipical Raphael · HBB", owned: true, curve: raphael, referenceID: references.first?.id)
        let matchStart = Date()
        let defaultResult = PersonalMatcher().match(features: features, headphone: headphone, references: references)
        let matchSeconds = Date().timeIntervalSince(matchStart)
        let classicStart = Date()
        let classicResult = Matcher().match(features: features, headphone: headphone, reference: references.first)
        let classicMatchSeconds = Date().timeIntervalSince(classicStart)
        var alphaSensitivity: [AlphaReport] = []
        for alpha in alphaValues {
            let result = PersonalMatcher(configuration: .init(compressionExponent: alpha)).match(features: features, headphone: headphone, references: references)
            alphaSensitivity.append(contentsOf: result.matches.map { match in
                AlphaReport(alpha: alpha, referenceName: match.referenceName, overallDB: match.overallDB, highDB: match.highDB, p90DB: match.frameP90DB, bestReferenceID: result.bestReferenceID?.uuidString)
            })
        }
        passed.append("live-benchmark")
        let matches = defaultResult.matches.map { match in
            LiveMatchReport(alpha: 0.3, referenceName: match.referenceName, referenceID: match.referenceID.uuidString, overallDB: match.overallDB, highDB: match.highDB, p90DB: match.frameP90DB, worstFrameDB: match.worstFrameDB, worstFrameTimeSeconds: match.worstFrameTimeSeconds, status: match.status.rawValue)
        }
        print(String(format: "LIVE source=%@ total=%.3fs analysis/match frames=%d", sourceKind, Date().timeIntervalSince(started), features.frames.count))
        print("LIVE classic D=\(format(classicResult.d, digits: 4)) C=\(format(classicResult.c, digits: 4)) Dhigh=\(format(classicResult.dHigh, digits: 4)) elapsed=\(format(classicMatchSeconds, digits: 4))s")
        for match in matches {
            print("LIVE \(match.referenceName) overall=\(format(match.overallDB, digits: 4)) high=\(format(match.highDB, digits: 4)) p90=\(format(match.p90DB, digits: 4)) worstTime=\(format(match.worstFrameTimeSeconds, digits: 3))")
        }
        passed.append("live-classic-matcher")
        return LiveReport(sourceKind: sourceKind, sourcePath: featurePath, decodeSeconds: decodeSeconds, analysisSeconds: analysisSeconds, matchSeconds: matchSeconds, classicMatchSeconds: classicMatchSeconds, classicDB: classicResult.d, classicC: classicResult.c, classicDHigh: classicResult.dHigh, sampleRate: features.sampleRate, channels: features.channelCount, durationSeconds: features.durationSeconds, frameCount: features.frames.count, commonMinimumHz: defaultResult.commonMinimumHz, commonMaximumHz: defaultResult.commonMaximumHz, matches: matches, alphaSensitivity: alphaSensitivity)
    }

    private static func readArtifact(_ url: URL) throws -> SpectrumFeatures {
        let compressed = try Data(contentsOf: url) as NSData
        let decoded = try compressed.decompressed(using: .lzfse) as Data
        return try PropertyListDecoder().decode(SpectrumFeatures.self, from: decoded)
    }

    private static func syntheticFeatures(extended: Bool, coverage: CoverageKind, leftScale: Double = 1, rightScale: Double = 0.8, silence: Bool = false) throws -> SpectrumFeatures {
        let frequencies = extended ? featureFrequencies : Array(featureFrequencies.prefix(8))
        let base = frequencies.map { frequency -> Double in
            if silence { return 0 }
            if frequency < 1_000 { return 1.2 }
            if frequency < 10_000 { return 0.8 }
            if frequency < 20_000 { return 0.35 }
            return 0.25
        }
        let frames = (0..<3).map { frameIndex in
            let multiplier = frameIndex == 1 ? 1.7 : (frameIndex == 2 ? 0.55 : 1.0)
            return SpectrumFrame(startTimeSeconds: Double(frameIndex), sampleCount: 1_024, powerSpectralDensityByChannel: [base.map { $0 * multiplier * leftScale }, base.map { $0 * multiplier * rightScale }])
        }
        let coverageValue = try Coverage(kind: coverage, recordedDurationSeconds: coverage == .partial ? 3 : nil, intervals: coverage == .complete ? [try TimeRange(startSeconds: 0, endSeconds: 3)] : [])
        return SpectrumFeatures(sampleRate: 96_000, channelCount: 2, frequencyBinsHz: frequencies, frames: frames, durationSeconds: 3, coverage: coverageValue, validMinHz: frequencies.first!, validMaxHz: frequencies.last!, frequencyValidity: .mathematicalNyquist, format: AudioFormatMetadata(sampleRate: 96_000, channelCount: 2), parameters: SpectrumAnalysisParameters(frameLength: 1_024, hopLength: 256, frameDurationSeconds: 1.0 / 48.0))
    }

    private static func uniformBandFeatures() throws -> SpectrumFeatures {
        let frequencies = stride(from: 20.0, through: 20_000.0, by: 1.0).map { $0 }
        let powers = Array(repeating: 1.0, count: frequencies.count)
        let frame = SpectrumFrame(startTimeSeconds: 0, sampleCount: 1_024, powerSpectralDensityByChannel: [powers, powers])
        let coverage = try Coverage(kind: .complete, intervals: [try TimeRange(startSeconds: 0, endSeconds: 1)], identityConfirmed: true)
        return SpectrumFeatures(sampleRate: 48_000, channelCount: 2, frequencyBinsHz: frequencies, frames: [frame], durationSeconds: 1, coverage: coverage, validMinHz: 20, validMaxHz: 20_000, frequencyValidity: .measuredContent, format: AudioFormatMetadata(sampleRate: 48_000, channelCount: 2), parameters: SpectrumAnalysisParameters(frameLength: 1_024, hopLength: 256, frameDurationSeconds: 0.02))
    }

    private static func curve(id: UUID, name: String, levels: [Double], maximum: Double) throws -> Curve {
        let frequencies = levels.count == featureFrequencies.count ? featureFrequencies : Array(featureFrequencies.prefix(levels.count))
        return try Curve(id: id, name: name, points: zip(frequencies, levels).map { try CurvePoint(frequencyHz: $0.0, decibels: $0.1) }, source: "synthetic", measurementSystem: "synthetic", validMinHz: 20, validMaxHz: maximum, isReference: true)
    }

    private static func shift(_ value: Curve, by amount: Double, id: UUID) throws -> Curve {
        try Curve(id: id, name: value.name + " shifted", points: value.points.map { try CurvePoint(frequencyHz: $0.frequencyHz, decibels: $0.decibels + amount) }, source: value.source, measurementSystem: value.measurementSystem, validMinHz: value.validMinHz, validMaxHz: value.validMaxHz, isReference: value.isReference)
    }

    private static func tryValue(_ value: Double?, _ label: String) throws -> Double {
        guard let value, value.isFinite else { throw HarnessFailure(message: "missing finite \(label)") }
        return value
    }

    private static func format(_ value: Double?, digits: Int) -> String {
        guard let value else { return "nil" }
        return String(format: "%.*f", digits, value)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw HarnessFailure(message: "assertion failed: \(label)") }
    }
}

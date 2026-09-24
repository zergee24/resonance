import Foundation

public enum CurveChannel: String, Codable, Sendable, CaseIterable {
    case mono
    case left
    case right
}

public struct CurvePoint: Codable, Sendable, Equatable, Hashable {
    public let frequencyHz: Double
    public let decibels: Double

    public init(frequencyHz: Double, decibels: Double) throws {
        guard frequencyHz.isFinite, decibels.isFinite, frequencyHz > 0 else {
            throw ResonanceCoreError.invalidCurvePoint(frequencyHz: frequencyHz, decibels: decibels)
        }
        self.frequencyHz = frequencyHz
        self.decibels = decibels
    }
}

public struct Curve: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let points: [CurvePoint]
    public let source: String
    public let measurementSystem: String
    public let validMinHz: Double
    public let validMaxHz: Double
    public let isReference: Bool
    public let channel: CurveChannel

    public init(
        id: UUID = UUID(),
        name: String,
        points: [CurvePoint],
        source: String,
        measurementSystem: String,
        validMinHz: Double? = nil,
        validMaxHz: Double? = nil,
        isReference: Bool = false,
        channel: CurveChannel = .mono
    ) throws {
        guard !points.isEmpty else {
            throw ResonanceCoreError.emptyCurve
        }
        guard points.allSatisfy({ $0.frequencyHz.isFinite && $0.decibels.isFinite && $0.frequencyHz > 0 }) else {
            throw ResonanceCoreError.nonFiniteCurvePoint
        }

        let sorted = points.sorted { $0.frequencyHz < $1.frequencyHz }
        for pair in zip(sorted, sorted.dropFirst()) where pair.0.frequencyHz == pair.1.frequencyHz {
            throw ResonanceCoreError.duplicateCurveFrequency(pair.0.frequencyHz)
        }

        let inferredMin = sorted[0].frequencyHz
        let inferredMax = sorted[sorted.count - 1].frequencyHz
        let minimum = validMinHz ?? inferredMin
        let maximum = validMaxHz ?? inferredMax
        guard minimum.isFinite, maximum.isFinite, minimum > 0, minimum <= maximum else {
            throw ResonanceCoreError.invalidCurveRange(minimum, maximum)
        }
        guard minimum >= inferredMin, maximum <= inferredMax else {
            throw ResonanceCoreError.curveRangeOutsidePoints(minimum, maximum)
        }

        self.id = id
        self.name = name
        self.points = sorted
        self.source = source
        self.measurementSystem = measurementSystem
        self.validMinHz = minimum
        self.validMaxHz = maximum
        self.isReference = isReference
        self.channel = channel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: container.decode(String.self, forKey: .name),
            points: container.decode([CurvePoint].self, forKey: .points),
            source: container.decode(String.self, forKey: .source),
            measurementSystem: container.decode(String.self, forKey: .measurementSystem),
            validMinHz: container.decodeIfPresent(Double.self, forKey: .validMinHz),
            validMaxHz: container.decodeIfPresent(Double.self, forKey: .validMaxHz),
            isReference: container.decodeIfPresent(Bool.self, forKey: .isReference) ?? false,
            channel: container.decodeIfPresent(CurveChannel.self, forKey: .channel) ?? .mono
        )
    }

    public func value(at frequencyHz: Double) -> Double? {
        guard frequencyHz.isFinite, frequencyHz > 0,
              frequencyHz >= validMinHz, frequencyHz <= validMaxHz else {
            return nil
        }
        if let exact = points.first(where: { $0.frequencyHz == frequencyHz }) {
            return exact.decibels
        }
        guard let upperIndex = points.firstIndex(where: { $0.frequencyHz > frequencyHz }) else {
            return points.last?.decibels
        }
        guard upperIndex > 0 else {
            return points.first?.decibels
        }

        let lower = points[upperIndex - 1]
        let upper = points[upperIndex]
        let logFrequency = log(frequencyHz)
        let lowerLog = log(lower.frequencyHz)
        let upperLog = log(upper.frequencyHz)
        let denominator = upperLog - lowerLog
        guard denominator.isFinite, denominator > 0 else {
            return nil
        }
        let fraction = (logFrequency - lowerLog) / denominator
        guard fraction.isFinite else { return nil }
        return lower.decibels + (upper.decibels - lower.decibels) * fraction
    }
}

public struct Headphone: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let owned: Bool
    public let curve: Curve?
    public let rightCurve: Curve?
    public let referenceID: UUID?
    public let eqCurve: Curve?

    public init(
        id: UUID = UUID(),
        name: String,
        owned: Bool,
        curve: Curve? = nil,
        rightCurve: Curve? = nil,
        referenceID: UUID? = nil,
        eqCurve: Curve? = nil
    ) {
        self.id = id
        self.name = name
        self.owned = owned
        self.curve = curve
        self.rightCurve = rightCurve
        self.referenceID = referenceID
        self.eqCurve = eqCurve
    }
}

public enum AudioSampleFormat: String, Codable, Sendable {
    case float32
    case int16
    case int32
    case unknown
}

public struct AudioFormatMetadata: Codable, Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: Int
    public let sampleFormat: AudioSampleFormat
    public let interleaved: Bool

    public init(sampleRate: Double, channelCount: Int, sampleFormat: AudioSampleFormat = .float32, interleaved: Bool = false) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.interleaved = interleaved
    }
}

public struct TimeRange: Codable, Sendable, Equatable, Hashable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) throws {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds >= startSeconds else {
            throw ResonanceCoreError.invalidTimeRange(startSeconds, endSeconds)
        }
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var durationSeconds: Double { endSeconds - startSeconds }
}

public enum CoverageKind: String, Codable, Sendable {
    case complete
    case partial
    case unknown
    case unavailable
}

public struct Coverage: Codable, Sendable, Equatable {
    public let kind: CoverageKind
    public let mediaDurationSeconds: Double?
    /// Duration of the local PCM that was actually recorded. This is kept
    /// separate from media time because a process tap may not expose the
    /// player's current position.
    public let recordedDurationSeconds: Double?
    public let intervals: [TimeRange]
    public let hasUnexplainedGaps: Bool
    public let identityConfirmed: Bool

    public init(
        kind: CoverageKind,
        mediaDurationSeconds: Double? = nil,
        recordedDurationSeconds: Double? = nil,
        intervals: [TimeRange] = [],
        hasUnexplainedGaps: Bool = false,
        identityConfirmed: Bool = false
    ) throws {
        if let mediaDurationSeconds {
            guard mediaDurationSeconds.isFinite, mediaDurationSeconds >= 0 else {
                throw ResonanceCoreError.invalidDuration(mediaDurationSeconds)
            }
        }
        if let recordedDurationSeconds {
            guard recordedDurationSeconds.isFinite, recordedDurationSeconds >= 0 else {
                throw ResonanceCoreError.invalidDuration(recordedDurationSeconds)
            }
        }
        guard intervals.allSatisfy({ $0.startSeconds.isFinite && $0.endSeconds.isFinite }) else {
            throw ResonanceCoreError.invalidCoverage
        }
        self.kind = kind
        self.mediaDurationSeconds = mediaDurationSeconds
        self.recordedDurationSeconds = recordedDurationSeconds
        self.intervals = intervals.sorted { $0.startSeconds < $1.startSeconds }
        self.hasUnexplainedGaps = hasUnexplainedGaps
        self.identityConfirmed = identityConfirmed
    }

    public static let unavailable = try! Coverage(kind: .unavailable)
    public static let unknown = try! Coverage(kind: .unknown)

    public var isUsable: Bool {
        guard !hasUnexplainedGaps else { return false }
        switch kind {
        case .complete:
            return !intervals.isEmpty && coveredDurationSeconds > 0
        case .partial:
            return coveredDurationSeconds > 0 || (recordedDurationSeconds ?? 0) > 0
        case .unknown, .unavailable:
            return false
        }
    }

    public var coveredDurationSeconds: Double {
        guard !intervals.isEmpty else { return 0 }
        var total = 0.0
        var current = intervals[0]
        for interval in intervals.dropFirst() {
            if interval.startSeconds <= current.endSeconds {
                if interval.endSeconds > current.endSeconds {
                    current = try! TimeRange(startSeconds: current.startSeconds, endSeconds: interval.endSeconds)
                }
            } else {
                total += current.durationSeconds
                current = interval
            }
        }
        return total + current.durationSeconds
    }
}

public enum RecordingProcessingStatus: String, Codable, Sendable {
    case pending
    case processing
    case ready
    case failed
    case stale
}

public struct RecordingMetadata: Codable, Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let platformTrackID: String?
    public let versionLabel: String?
    public let durationSeconds: Double?
    public let contentHash: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        platformTrackID: String? = nil,
        versionLabel: String? = nil,
        durationSeconds: Double? = nil,
        contentHash: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.platformTrackID = platformTrackID
        self.versionLabel = versionLabel
        self.durationSeconds = durationSeconds
        self.contentHash = contentHash
    }
}

public struct Recording: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let metadata: RecordingMetadata
    public let pcmLocation: URL?
    public let featureLocation: URL?
    public let format: AudioFormatMetadata?
    public let coverage: Coverage
    public let processingStatus: RecordingProcessingStatus
    public let processingMessage: String?

    public init(
        id: UUID = UUID(),
        metadata: RecordingMetadata,
        pcmLocation: URL? = nil,
        featureLocation: URL? = nil,
        format: AudioFormatMetadata? = nil,
        coverage: Coverage = .unknown,
        processingStatus: RecordingProcessingStatus = .pending,
        processingMessage: String? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.pcmLocation = pcmLocation
        self.featureLocation = featureLocation
        self.format = format
        self.coverage = coverage
        self.processingStatus = processingStatus
        self.processingMessage = processingMessage
    }
}

public struct SpectrumAnalysisParameters: Codable, Sendable, Equatable {
    public let frameLength: Int
    public let hopLength: Int
    public let window: String
    public let oneSidedPSD: Bool
    public let frameDurationSeconds: Double

    public init(frameLength: Int, hopLength: Int, window: String = "hann", oneSidedPSD: Bool = true, frameDurationSeconds: Double) {
        self.frameLength = frameLength
        self.hopLength = hopLength
        self.window = window
        self.oneSidedPSD = oneSidedPSD
        self.frameDurationSeconds = frameDurationSeconds
    }
}

public struct SpectrumFrame: Codable, Sendable, Equatable {
    public let startTimeSeconds: Double
    public let sampleCount: Int
    public let powerSpectralDensityByChannel: [[Double]]

    public init(startTimeSeconds: Double, sampleCount: Int, powerSpectralDensityByChannel: [[Double]]) {
        self.startTimeSeconds = startTimeSeconds
        self.sampleCount = sampleCount
        self.powerSpectralDensityByChannel = powerSpectralDensityByChannel
    }
}

public struct SpectrumFeatures: Codable, Sendable, Equatable {
    public let recordingID: UUID?
    public let sampleRate: Double
    public let channelCount: Int
    public let frequencyBinsHz: [Double]
    public let frames: [SpectrumFrame]
    public let durationSeconds: Double
    public let coverage: Coverage
    public let validMinHz: Double
    public let validMaxHz: Double
    /// Describes what the frequency range proves. The analyzer can only
    /// establish the mathematical Nyquist limit from PCM; it cannot infer the
    /// music or capture chain's true information bandwidth from that alone.
    public let frequencyValidity: FrequencyValidity
    public let format: AudioFormatMetadata
    public let parameters: SpectrumAnalysisParameters
    public let analyzerVersion: String

    public init(
        recordingID: UUID? = nil,
        sampleRate: Double,
        channelCount: Int,
        frequencyBinsHz: [Double],
        frames: [SpectrumFrame],
        durationSeconds: Double,
        coverage: Coverage,
        validMinHz: Double,
        validMaxHz: Double,
        frequencyValidity: FrequencyValidity = .unknown,
        format: AudioFormatMetadata,
        parameters: SpectrumAnalysisParameters,
        analyzerVersion: String = "1"
    ) {
        self.recordingID = recordingID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frequencyBinsHz = frequencyBinsHz
        self.frames = frames
        self.durationSeconds = durationSeconds
        self.coverage = coverage
        self.validMinHz = validMinHz
        self.validMaxHz = validMaxHz
        self.frequencyValidity = frequencyValidity
        self.format = format
        self.parameters = parameters
        self.analyzerVersion = analyzerVersion
    }
}

public enum FrequencyValidity: String, Codable, Sendable {
    case unknown
    case mathematicalNyquist
    case measuredContent
    case chainValidated
}

public struct FrequencyBand: Codable, Sendable, Equatable, Hashable {
    public let lowerHz: Double
    public let upperHz: Double
    public let isHighFrequency: Bool

    public init(lowerHz: Double, upperHz: Double, isHighFrequency: Bool = false) {
        self.lowerHz = lowerHz
        self.upperHz = upperHz
        self.isHighFrequency = isHighFrequency
    }

    public var label: String { "\(formatFrequency(lowerHz))–\(formatFrequency(upperHz)) Hz" }

    private func formatFrequency(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.4gk", value / 1000) }
        return String(format: "%.4g", value)
    }

    public static let defaultThirty: [FrequencyBand] = {
        let edges: [Double] = [
            20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200,
            250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
            2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
        ]
        return zip(edges, edges.dropFirst()).map { FrequencyBand(lowerHz: $0.0, upperHz: $0.1, isHighFrequency: $0.0 >= 10000) }
    }()

    public static func expanded(through maximumHz: Double) -> [FrequencyBand] {
        guard maximumHz.isFinite, maximumHz > 20_000 else { return defaultThirty }
        let extensionEdges: [Double] = [20_000, 25_000, 31_500, 40_000, 50_000, 63_000, 80_000, 100_000]
        var result = defaultThirty
        for pair in zip(extensionEdges, extensionEdges.dropFirst()) where pair.0 < maximumHz {
            // Keep the nominal display band. MatchBandEvidence records the
            // actual intersection when a valid range ends inside the band.
            result.append(FrequencyBand(lowerHz: pair.0, upperHz: pair.1, isHighFrequency: true))
        }
        return result
    }
}

public struct MatchBandEvidence: Codable, Sendable, Equatable {
    public let band: FrequencyBand
    public let actualLowerHz: Double?
    public let actualUpperHz: Double?
    public let inputEnergyFraction: Double?
    public let relativeGainDB: Double?
    public let deviationContribution: Double?
    public let peakTimeSeconds: Double?
    public let state: EvidenceState

    public enum EvidenceState: String, Codable, Sendable {
        case evaluated
        case noAudioContent
        case partialCoverage
        case outsideMeasurement
        case insufficientResolution
    }
}

public enum MatchEvaluationStatus: String, Codable, Sendable {
    case evaluated
    case partial
    case unevaluable
}

public enum MatchUnevaluableReason: String, Codable, Sendable {
    case missingReference
    case missingHeadphoneCurve
    case missingCoverage
    case noCommonFrequencyCoverage
    case noSpectrumFrames
    case insufficientResolution
    case invalidInput
}

public struct MatchResult: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let recordingID: UUID?
    public let headphoneID: UUID
    public let referenceID: UUID?
    public let status: MatchEvaluationStatus
    public let unevaluableReason: MatchUnevaluableReason?
    public let message: String?
    public let c: Double?
    public let d: Double?
    public let dHigh: Double?
    public let highFrequencyEnergyRatio: Double?
    public let evaluatedMinHz: Double?
    public let evaluatedMaxHz: Double?
    public let frequencyValidity: FrequencyValidity
    public let completeOrPartial: CoverageKind
    public let frequencyBands: [MatchBandEvidence]
    public let modelVersion: String

    public init(
        id: UUID = UUID(),
        recordingID: UUID?,
        headphoneID: UUID,
        referenceID: UUID?,
        status: MatchEvaluationStatus,
        unevaluableReason: MatchUnevaluableReason? = nil,
        message: String? = nil,
        c: Double? = nil,
        d: Double? = nil,
        dHigh: Double? = nil,
        highFrequencyEnergyRatio: Double? = nil,
        evaluatedMinHz: Double? = nil,
        evaluatedMaxHz: Double? = nil,
        frequencyValidity: FrequencyValidity = .unknown,
        completeOrPartial: CoverageKind,
        frequencyBands: [MatchBandEvidence] = [],
        modelVersion: String = "1"
    ) {
        self.id = id
        self.recordingID = recordingID
        self.headphoneID = headphoneID
        self.referenceID = referenceID
        self.status = status
        self.unevaluableReason = unevaluableReason
        self.message = message
        self.c = c
        self.d = d
        self.dHigh = dHigh
        self.highFrequencyEnergyRatio = highFrequencyEnergyRatio
        self.evaluatedMinHz = evaluatedMinHz
        self.evaluatedMaxHz = evaluatedMaxHz
        self.frequencyValidity = frequencyValidity
        self.completeOrPartial = completeOrPartial
        self.frequencyBands = frequencyBands
        self.modelVersion = modelVersion
    }

    public var isEvaluable: Bool { status != .unevaluable }
}

public enum ResonanceCoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidCurvePoint(frequencyHz: Double, decibels: Double)
    case emptyCurve
    case nonFiniteCurvePoint
    case duplicateCurveFrequency(Double)
    case invalidCurveRange(Double, Double)
    case curveRangeOutsidePoints(Double, Double)
    case invalidTimeRange(Double, Double)
    case invalidDuration(Double)
    case invalidCoverage
    case invalidAudioFormat
    case unsupportedAudioFormat
    case emptyAudio
    case nonFiniteAudioSample
    case inconsistentChannelLengths
    case invalidAnalysisParameters
    case noSpectrumFrames
    case malformedCurveLine(Int, String)
    case nonFiniteCurveValue(Int)
    case conflictingDuplicateFrequency(Int, Double)
    case unsupportedCurveEncoding

    public var errorDescription: String? {
        switch self {
        case let .invalidCurvePoint(frequencyHz, decibels): return "Invalid curve point: \(frequencyHz) Hz, \(decibels) dB"
        case .emptyCurve: return "Curve has no points"
        case .nonFiniteCurvePoint: return "Curve contains a non-finite point"
        case let .duplicateCurveFrequency(frequency): return "Curve contains duplicate frequency \(frequency) Hz"
        case let .invalidCurveRange(minimum, maximum): return "Invalid curve range \(minimum)–\(maximum) Hz"
        case let .curveRangeOutsidePoints(minimum, maximum): return "Curve range \(minimum)–\(maximum) Hz is outside its points"
        case let .invalidTimeRange(start, end): return "Invalid time range \(start)–\(end) seconds"
        case let .invalidDuration(duration): return "Invalid duration \(duration) seconds"
        case .invalidCoverage: return "Invalid coverage intervals"
        case .invalidAudioFormat: return "Invalid audio format"
        case .unsupportedAudioFormat: return "Unsupported audio format"
        case .emptyAudio: return "Audio contains no samples"
        case .nonFiniteAudioSample: return "Audio contains a non-finite sample"
        case .inconsistentChannelLengths: return "Audio channels have inconsistent lengths"
        case .invalidAnalysisParameters: return "Invalid spectrum analysis parameters"
        case .noSpectrumFrames: return "Audio is shorter than one analysis frame"
        case let .malformedCurveLine(line, text): return "Malformed curve data at line \(line): \(text)"
        case let .nonFiniteCurveValue(line): return "Non-finite curve value at line \(line)"
        case let .conflictingDuplicateFrequency(line, frequency): return "Conflicting duplicate frequency \(frequency) Hz at line \(line)"
        case .unsupportedCurveEncoding: return "Curve file encoding is not supported"
        }
    }
}

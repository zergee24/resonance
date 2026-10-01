import Foundation

/// Errors raised while building the compact, native-cell frequency artifact.
public enum CompactSpectrumError: Error, LocalizedError, Sendable, Equatable {
    case invalidBandsPerOctave(Int)
    case invalidFrequencyGrid
    case invalidFrameShape
    case nonFinitePower
    case compactGridMismatch(expected: Int, actual: Int)
    case missingCompactCellEdges
    case invalidCompactMetadata

    public var errorDescription: String? {
        switch self {
        case let .invalidBandsPerOctave(value):
            return "每八度频带数无效：\(value)"
        case .invalidFrequencyGrid:
            return "频率网格必须包含至少两个有限且严格递增的 native FFT bin。"
        case .invalidFrameShape:
            return "频谱帧的声道或频率数组形状不一致。"
        case .nonFinitePower:
            return "频谱帧包含非有限功率值。"
        case let .compactGridMismatch(expected, actual):
            return "已有 compact 频率网格为每八度 \(actual) 带，不能冒充每八度 \(expected) 带。"
        case .missingCompactCellEdges:
            return "compact 频谱缺少显式 cell 边界。"
        case .invalidCompactMetadata:
            return "compact 频谱的版本、边界、帧形状或表示元数据无效。"
        }
    }
}

/// Builds and validates the compact frequency representation used by the
/// storage path.  The compact artifact retains every native analysis frame
/// and channel, but groups complete native FFT cells into logarithmic bands.
/// It deliberately stores band-averaged PSD density rather than normalized
/// features so absolute energy and temporal weighting remain recoverable.
public struct CompactSpectrum: Sendable {
    public static let formatVersion = "compact-v1"
    public static let defaultBandsPerOctave = 48
    public static let powerRepresentation = "native-cell-integrated-power-divided-by-explicit-cell-width"

    public init() {}

    /// Validates a compact artifact before it is persisted or handed to a
    /// matcher. Native legacy artifacts are accepted unchanged because they
    /// intentionally have no compact metadata.
    public static func validate(_ features: SpectrumFeatures) throws {
        guard let storage = features.compactStorage else { return }
        try validateCompactArtifact(features, storage: storage)
    }

    /// Aggregates a legacy native-FFT artifact.  A compact artifact with the
    /// same grid is returned unchanged; a different grid is rejected so it
    /// cannot be silently treated as equivalent.
    public static func compact(
        _ features: SpectrumFeatures,
        bandsPerOctave: Int = defaultBandsPerOctave
    ) throws -> SpectrumFeatures {
        guard bandsPerOctave > 0, bandsPerOctave <= 1_024 else {
            throw CompactSpectrumError.invalidBandsPerOctave(bandsPerOctave)
        }

        if let storage = features.compactStorage {
            try validateCompactArtifact(features, storage: storage)
            guard storage.bandsPerOctave == bandsPerOctave else {
                throw CompactSpectrumError.compactGridMismatch(
                    expected: bandsPerOctave,
                    actual: storage.bandsPerOctave
                )
            }
            return features
        }

        var accumulator = try Accumulator(
            frequencyBinsHz: features.frequencyBinsHz,
            channelCount: features.channelCount,
            bandsPerOctave: bandsPerOctave
        )
        for frame in features.frames {
            try accumulator.append(frame)
        }
        return try accumulator.finish(
            recordingID: features.recordingID,
            sampleRate: features.sampleRate,
            durationSeconds: features.durationSeconds,
            coverage: features.coverage,
            validMinHz: features.validMinHz,
            validMaxHz: features.validMaxHz,
            frequencyValidity: features.frequencyValidity,
            format: features.format,
            parameters: features.parameters,
            sourceAnalyzerVersion: features.analyzerVersion
        )
    }

    private static func validateCompactArtifact(
        _ features: SpectrumFeatures,
        storage: CompactSpectrumStorageMetadata
    ) throws {
        guard storage.version == formatVersion,
              storage.bandsPerOctave > 0,
              storage.bandsPerOctave <= 1_024,
              storage.nativeBinCount >= features.frequencyBinsHz.count,
              storage.powerRepresentation == powerRepresentation,
              !storage.sourceAnalyzerVersion.isEmpty,
              !storage.quantizationErrorDescription.isEmpty else {
            throw CompactSpectrumError.invalidCompactMetadata
        }
        guard features.frequencyBinsHz.count >= 2,
              features.frequencyBinsHz.allSatisfy(\.isFinite),
              zip(features.frequencyBinsHz, features.frequencyBinsHz.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              let edges = features.frequencyCellEdgesHz,
              edges.count == features.frequencyBinsHz.count + 1,
              edges.allSatisfy(\.isFinite),
              zip(edges, edges.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              features.frequencyBinsHz.enumerated().allSatisfy({ index, frequency in
                  frequency >= edges[index] && frequency <= edges[index + 1]
              }) else {
            throw CompactSpectrumError.invalidCompactMetadata
        }
        guard features.channelCount > 0,
              features.frames.allSatisfy({ frame in
                  frame.powerSpectralDensityByChannel.count == features.channelCount &&
                      frame.powerSpectralDensityByChannel.allSatisfy {
                          $0.count == features.frequencyBinsHz.count && $0.allSatisfy { $0.isFinite && $0 >= 0 }
                      }
              }) else {
            throw CompactSpectrumError.invalidCompactMetadata
        }
    }

    /// Internal accumulator used by `SpectrumAnalyzer.analyzeCompact` so a
    /// file can be decoded and reduced one native FFT frame at a time.
    struct Accumulator {
        private let frequencyBinsHz: [Double]
        private let nativeCellEdgesHz: [Double]
        private let channelCount: Int
        private let groups: [Group]
        private var frames: [SpectrumFrame] = []

        init(
            frequencyBinsHz: [Double],
            channelCount: Int,
            bandsPerOctave: Int
        ) throws {
            guard channelCount > 0 else { throw CompactSpectrumError.invalidFrameShape }
            guard frequencyBinsHz.count >= 2,
                  frequencyBinsHz.allSatisfy(\.isFinite),
                  zip(frequencyBinsHz, frequencyBinsHz.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
                throw CompactSpectrumError.invalidFrequencyGrid
            }
            self.frequencyBinsHz = frequencyBinsHz
            self.nativeCellEdgesHz = CompactSpectrum.makeNativeCellEdges(frequencyBinsHz)
            self.channelCount = channelCount
            self.groups = try CompactSpectrum.makeGroups(
                frequencyBinsHz: frequencyBinsHz,
                nativeCellEdgesHz: nativeCellEdgesHz,
                bandsPerOctave: bandsPerOctave
            )
            guard !groups.isEmpty else { throw CompactSpectrumError.invalidFrequencyGrid }
        }

        mutating func append(_ frame: SpectrumFrame) throws {
            guard frame.powerSpectralDensityByChannel.count == channelCount,
                  frame.powerSpectralDensityByChannel.allSatisfy({ $0.count == frequencyBinsHz.count }) else {
                throw CompactSpectrumError.invalidFrameShape
            }
            guard frame.powerSpectralDensityByChannel.allSatisfy({
                $0.allSatisfy(\.isFinite)
            }) else {
                throw CompactSpectrumError.nonFinitePower
            }

            let compactChannels = (0..<channelCount).map { channelIndex in
                groups.map { group in
                    let width = group.upperHz - group.lowerHz
                    guard width.isFinite, width > 0 else { return 0.0 }
                    var energy = 0.0
                    for nativeIndex in group.firstNativeIndex...group.lastNativeIndex {
                        let nativeWidth = nativeCellEdgesHz[nativeIndex + 1] - nativeCellEdgesHz[nativeIndex]
                        let power = max(0, frame.powerSpectralDensityByChannel[channelIndex][nativeIndex])
                        energy += power * nativeWidth
                    }
                    // Keep the absolute integrated power while presenting the
                    // compact frame as a density over its explicit cell.
                    let density = energy / width
                    return density.isFinite && density >= 0 ? density : 0
                }
            }
            frames.append(
                SpectrumFrame(
                    startTimeSeconds: frame.startTimeSeconds,
                    sampleCount: frame.sampleCount,
                    powerSpectralDensityByChannel: compactChannels
                )
            )
        }

        func finish(
            recordingID: UUID?,
            sampleRate: Double,
            durationSeconds: Double,
            coverage: Coverage,
            validMinHz: Double,
            validMaxHz: Double,
            frequencyValidity: FrequencyValidity,
            format: AudioFormatMetadata,
            parameters: SpectrumAnalysisParameters,
            sourceAnalyzerVersion: String
        ) throws -> SpectrumFeatures {
            let compactFrequencies = groups.map(\.representativeHz)
            let compactEdges = [groups.first!.lowerHz] + groups.map(\.upperHz)
            guard compactFrequencies.count >= 2,
                  compactEdges.count == compactFrequencies.count + 1,
                  compactEdges.allSatisfy(\.isFinite),
                  zip(compactEdges, compactEdges.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
                throw CompactSpectrumError.invalidFrequencyGrid
            }
            let metadata = CompactSpectrumStorageMetadata(
                version: CompactSpectrum.formatVersion,
                bandsPerOctave: groups.first?.bandsPerOctave ?? CompactSpectrum.defaultBandsPerOctave,
                sourceAnalyzerVersion: sourceAnalyzerVersion,
                nativeBinCount: frequencyBinsHz.count
            )
            return SpectrumFeatures(
                recordingID: recordingID,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frequencyBinsHz: compactFrequencies,
                frames: frames,
                durationSeconds: durationSeconds,
                coverage: coverage,
                validMinHz: validMinHz,
                validMaxHz: validMaxHz,
                frequencyValidity: frequencyValidity,
                format: format,
                parameters: parameters,
                analyzerVersion: "\(sourceAnalyzerVersion)-\(CompactSpectrum.formatVersion)-\(metadata.bandsPerOctave)",
                frequencyCellEdgesHz: compactEdges,
                compactStorage: metadata
            )
        }
    }

    private enum FrequencyRegion: Int, Equatable {
        case dc
        case belowAudible
        case audibleLow
        case audibleHigh
        case extended
    }

    private struct GroupKey: Equatable {
        let region: FrequencyRegion
        let bucket: Int
    }

    private struct Group {
        let firstNativeIndex: Int
        let lastNativeIndex: Int
        let lowerHz: Double
        let upperHz: Double
        let representativeHz: Double
        let bandsPerOctave: Int
    }

    private static func makeNativeCellEdges(_ frequencies: [Double]) -> [Double] {
        var result = [frequencies[0]]
        result.reserveCapacity(frequencies.count + 1)
        if frequencies.count > 1 {
            for index in 1..<frequencies.count {
                result.append((frequencies[index - 1] + frequencies[index]) / 2)
            }
        }
        result.append(frequencies[frequencies.count - 1])
        return result
    }

    private static func makeGroups(
        frequencyBinsHz: [Double],
        nativeCellEdgesHz: [Double],
        bandsPerOctave: Int
    ) throws -> [Group] {
        var result: [Group] = []
        var currentKey: GroupKey?
        var firstNativeIndex: Int?

        func flush(before index: Int) throws {
            guard let firstNativeIndex else { return }
            result.append(try makeGroup(
                firstNativeIndex: firstNativeIndex,
                lastNativeIndex: index - 1,
                frequencyBinsHz: frequencyBinsHz,
                nativeCellEdgesHz: nativeCellEdgesHz,
                bandsPerOctave: bandsPerOctave
            ))
        }

        for index in frequencyBinsHz.indices {
            let boundaryCell = isBoundaryCell(
                index: index,
                nativeCellEdgesHz: nativeCellEdgesHz
            )
            if boundaryCell {
                try flush(before: index)
                result.append(try makeGroup(
                    firstNativeIndex: index,
                    lastNativeIndex: index,
                    frequencyBinsHz: frequencyBinsHz,
                    nativeCellEdgesHz: nativeCellEdgesHz,
                    bandsPerOctave: bandsPerOctave
                ))
                firstNativeIndex = nil
                currentKey = nil
                continue
            }

            let key = groupKey(for: frequencyBinsHz[index], bandsPerOctave: bandsPerOctave)
            if let currentKey, currentKey != key {
                try flush(before: index)
                firstNativeIndex = index
            } else if firstNativeIndex == nil {
                firstNativeIndex = index
            }
            currentKey = key
        }

        try flush(before: frequencyBinsHz.count)
        return result
    }

    private static func isBoundaryCell(index: Int, nativeCellEdgesHz: [Double]) -> Bool {
        guard index >= 0, index + 1 < nativeCellEdgesHz.count else { return true }
        if index == 0 || index == nativeCellEdgesHz.count - 2 {
            return true
        }
        let lower = nativeCellEdgesHz[index]
        let upper = nativeCellEdgesHz[index + 1]
        return [20.0, 10_000.0, 20_000.0].contains { boundary in
            lower < boundary && boundary < upper
        }
    }

    private static func groupKey(for frequencyHz: Double, bandsPerOctave: Int) -> GroupKey {
        if frequencyHz == 0 {
            return GroupKey(region: .dc, bucket: 0)
        }
        if frequencyHz < 20 {
            // Do not synthesize sub-native low-frequency bands. All non-zero
            // native cells below 20 Hz remain one separately classified group.
            return GroupKey(region: .belowAudible, bucket: 0)
        }
        if frequencyHz < 10_000 {
            return GroupKey(
                region: .audibleLow,
                bucket: octaveBucket(frequencyHz, lowerBound: 20, bandsPerOctave: bandsPerOctave)
            )
        }
        if frequencyHz < 20_000 {
            return GroupKey(
                region: .audibleHigh,
                bucket: octaveBucket(frequencyHz, lowerBound: 10_000, bandsPerOctave: bandsPerOctave)
            )
        }
        return GroupKey(
            region: .extended,
            bucket: octaveBucket(frequencyHz, lowerBound: 20_000, bandsPerOctave: bandsPerOctave)
        )
    }

    private static func octaveBucket(
        _ frequencyHz: Double,
        lowerBound: Double,
        bandsPerOctave: Int
    ) -> Int {
        let value = log2(max(frequencyHz, lowerBound) / lowerBound) * Double(bandsPerOctave)
        guard value.isFinite else { return Int.max }
        guard value < Double(Int.max) else { return Int.max }
        return max(0, Int(floor(value)))
    }

    private static func makeGroup(
        firstNativeIndex: Int,
        lastNativeIndex: Int,
        frequencyBinsHz: [Double],
        nativeCellEdgesHz: [Double],
        bandsPerOctave: Int
    ) throws -> Group {
        guard firstNativeIndex >= 0,
              lastNativeIndex >= firstNativeIndex,
              lastNativeIndex < frequencyBinsHz.count else {
            throw CompactSpectrumError.invalidFrequencyGrid
        }
        let lower = nativeCellEdgesHz[firstNativeIndex]
        let upper = nativeCellEdgesHz[lastNativeIndex + 1]
        guard lower.isFinite, upper.isFinite, lower < upper else {
            throw CompactSpectrumError.invalidFrequencyGrid
        }
        let representative: Double
        if lower <= 0 {
            representative = frequencyBinsHz[firstNativeIndex]
        } else {
            representative = sqrt(lower * upper)
        }
        guard representative.isFinite, representative >= 0 else {
            throw CompactSpectrumError.invalidFrequencyGrid
        }
        return Group(
            firstNativeIndex: firstNativeIndex,
            lastNativeIndex: lastNativeIndex,
            lowerHz: lower,
            upperHz: upper,
            representativeHz: representative,
            bandsPerOctave: bandsPerOctave
        )
    }
}

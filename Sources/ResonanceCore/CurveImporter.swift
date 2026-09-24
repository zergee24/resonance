import Foundation

public struct CurveImporter: Sendable {
    public init() {}

    public func load(
        from url: URL,
        name: String,
        source: String,
        measurementSystem: String,
        validMinHz: Double? = nil,
        validMaxHz: Double? = nil,
        isReference: Bool = false,
        channel: CurveChannel = .mono
    ) throws -> Curve {
        let data = try Data(contentsOf: url)
        guard var text = String(data: data, encoding: .utf8) else {
            throw ResonanceCoreError.unsupportedCurveEncoding
        }
        if text.first == "\u{FEFF}" {
            text.removeFirst()
        }
        return try parse(
            text: text,
            name: name,
            source: source,
            measurementSystem: measurementSystem,
            validMinHz: validMinHz,
            validMaxHz: validMaxHz,
            isReference: isReference,
            channel: channel
        )
    }

    public func parse(
        text: String,
        name: String,
        source: String,
        measurementSystem: String,
        validMinHz: Double? = nil,
        validMaxHz: Double? = nil,
        isReference: Bool = false,
        channel: CurveChannel = .mono
    ) throws -> Curve {
        var pointsByFrequency: [Double: (line: Int, decibels: Double)] = [:]
        var startedData = false
        var metadataStarted = false
        var sawData = false

        for (zeroBasedLine, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = zeroBasedLine + 1
            let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let tokens = tokenize(line)
            guard !tokens.isEmpty else { continue }
            if metadataStarted { continue }
            if startedData && isTrailingMetadata(tokens) {
                metadataStarted = true
                continue
            }
            let numericTokens = tokens.compactMap(Double.init)

            // A single header row is common in CSV/TXT exports. It is ignored
            // only before the first data row; malformed rows after data are an
            // import error so that a damaged curve cannot silently pass.
            if numericTokens.count < 2 {
                if !startedData && looksLikeHeader(tokens) {
                    continue
                }
                if !startedData {
                    continue
                }
                throw ResonanceCoreError.malformedCurveLine(lineNumber, rawLine)
            }

            guard tokens.count >= 2,
                  let frequency = Double(tokens[0]),
                  let decibels = Double(tokens[1]) else {
                if !startedData {
                    continue
                }
                throw ResonanceCoreError.malformedCurveLine(lineNumber, rawLine)
            }
            guard frequency.isFinite, decibels.isFinite else {
                throw ResonanceCoreError.nonFiniteCurveValue(lineNumber)
            }
            guard frequency > 0 else {
                throw ResonanceCoreError.malformedCurveLine(lineNumber, rawLine)
            }
            startedData = true
            sawData = true

            if let existing = pointsByFrequency[frequency] {
                if existing.decibels != decibels {
                    throw ResonanceCoreError.conflictingDuplicateFrequency(lineNumber, frequency)
                }
                // Exact duplicate rows are harmless and are deduplicated.
            } else {
                pointsByFrequency[frequency] = (lineNumber, decibels)
            }
        }

        guard sawData else { throw ResonanceCoreError.emptyCurve }
        let points = try pointsByFrequency
            .sorted { $0.key < $1.key }
            .map { try CurvePoint(frequencyHz: $0.key, decibels: $0.value.decibels) }
        return try Curve(
            name: name,
            points: points,
            source: source,
            measurementSystem: measurementSystem,
            validMinHz: validMinHz,
            validMaxHz: validMaxHz,
            isReference: isReference,
            channel: channel
        )
    }

    private func tokenize(_ line: String) -> [String] {
        let normalized = line
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\t", with: ",")
        if normalized.contains(",") {
            return normalized
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return normalized
            .split(whereSeparator: { $0 == " " || $0 == "\r" })
            .map(String.init)
    }

    private func stripComment(from line: String) -> String {
        let commentMarkers = ["#", "//"]
        var result = line
        for marker in commentMarkers {
            if let range = result.range(of: marker) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result
    }

    private func looksLikeHeader(_ tokens: [String]) -> Bool {
        let lower = tokens.joined(separator: " ").lowercased()
        return lower.contains("freq") || lower.contains("hz") || lower.contains("db") || lower.contains("decibel")
    }

    private func isTrailingMetadata(_ tokens: [String]) -> Bool {
        guard let first = tokens.first?
            .split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\t" })
            .first?
            .lowercased() else { return false }
        return ["overall", "decay", "averaging", "source", "latitude", "longitude", "saved", "peak"].contains(first)
    }
}

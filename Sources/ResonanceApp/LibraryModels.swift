import Foundation

enum WorkMode: String, CaseIterable, Identifiable {
    case song = "根据歌曲找耳机"
    case headphone = "根据耳机找歌曲"
    var id: String { rawValue }
    var icon: String { self == .song ? "waveform" : "headphones" }
    var subtitle: String { self == .song ? "让每首歌，找到合适的耳机。" : "听见这副耳机的特点。" }
}

struct LibraryCurve: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var frequencies: [Double]
    var levels: [Double]
    var rightLevels: [Double]?
    var source: String
    var measurementSystem: String
    var validMin: Double
    var validMax: Double
    var isReference: Bool
    var notes: String
    var importedAt = Date()
}

struct HeadphoneEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var curveID: UUID
    var referenceID: UUID?
    var owned = false
    var configuration = "原始测量配置"
}

struct TrackEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var artist: String
    var neteaseID: String?
    var sourceURL: String?
    var audioPath: String?
    var featurePath: String?
    var duration: Double?
    var capturedSeconds: Double = 0
    var sampleRate: Double?
    var channels: Int?
    var isFull = false
    var processingState = "播放处理未知"
    var source = "本地导入"
    var importedAt = Date()
    var sourcePlaylistID: UUID?
    var sourceOrder: Int = 0
    var error: String?
    var comparisonAllowed = true
    var mediaStartSeconds: Double?
    var wallClockStartedAt: Date?
    var contentSHA256: String?
    var droppedFrames: UInt64?
    var sourceProcessID: Int32?
    var analyzed: Bool { featurePath != nil }
    var coverageLabel: String { isFull ? "整曲" : "片段" }
}

struct PlaylistEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var providerID: String?
    var trackIDs: [UUID]
    var complete: Bool
    var note: String
    var importedAt = Date()
}

struct MatchPresentation: Identifiable {
    var id: String { "\(trackID.uuidString)-\(headphoneID.uuidString)" }
    var trackID: UUID
    var headphoneID: UUID
    var name: String
    var subtitle: String
    var c: Double?
    var d: Double?
    var high: Double?
    var reason: String
    var bands: [BandPresentation]
    var evaluatedMin: Double?
    var evaluatedMax: Double?
    var advantage: Double?
    var comparisonGroup = ""
    var eligible: Bool { d != nil }
}

struct BandPresentation: Identifiable {
    var id: String { "\(low)-\(high)" }
    var low: Double
    var high: Double
    var share: Double?
    var gain: Double?
    var deviation: Double?
    var status: String
    var actualLow: Double?
    var actualHigh: Double?
    var label: String { "\(frequencyLabel(low))–\(frequencyLabel(high))" }
}

enum SongSort: String, CaseIterable, Identifiable {
    case character = "特色探索"
    case balanced = "综合适配"
    case high = "超高频适配"
    var id: String { rawValue }
}

func frequencyLabel(_ value: Double) -> String {
    if value >= 1_000 { return String(format: "%gk", value / 1_000) }
    return String(format: "%g", value)
}

func durationLabel(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "—" }
    return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
}

func neteaseTrackID(from text: String) -> String? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let host = url.host, host == "music.163.com" || host.hasSuffix(".music.163.com") else { return nil }
    let normalized = text.replacingOccurrences(of: "/#/", with: "/")
    guard let parts = URLComponents(string: normalized), parts.path.contains("song"),
          let value = parts.queryItems?.first(where: { $0.name == "id" })?.value,
          !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
    return value
}

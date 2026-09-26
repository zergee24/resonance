import AppKit
import CoreGraphics
import Foundation

@main
struct OCRProbe {
    @MainActor
    static func main() throws {
        let observer = PlayerObserver(bundleIdentifiers: [], pollingInterval: 0.6)

        let normal = try makeSplitImage(width: 64, height: 256)
        guard let cropped = observer.cropBottomBar(from: normal) else {
            throw ProbeFailure("production crop returned nil for a valid image")
        }
        try require(cropped.width == normal.width, "crop changed image width")
        try require(cropped.height == 80, "crop must retain the 80-point playback bar")
        let normalColors = try pixelColors(cropped)
        try require(!normalColors.isEmpty && normalColors.allSatisfy { $0 == .blue }, "crop still contains pixels above the bottom bar")

        let retina = try makeSplitImage(width: 128, height: 512)
        guard let retinaCrop = observer.cropBottomBar(from: retina, scale: 2) else {
            throw ProbeFailure("production crop returned nil for a Retina image")
        }
        try require(retinaCrop.height == 160, "Retina crop lost its point-to-pixel scale")
        let retinaColors = try pixelColors(retinaCrop)
        try require(retinaColors.allSatisfy { $0 == .blue }, "Retina crop includes upper-window pixels")

        let small = try makeSplitImage(width: 16, height: 64)
        guard let smallCrop = observer.cropBottomBar(from: small) else {
            throw ProbeFailure("production crop returned nil for a small image")
        }
        try require(smallCrop.width == small.width && smallCrop.height == small.height, "small image crop exceeded image bounds")

        try verifyRedBadgeMask(observer)
        try verifyOCRStability()
        try verifySystemMetadata()
        try verifyLegacyTrackDecode()
        print("PASS production OCR crop probe: normal=\(cropped.width)x\(cropped.height), small=\(smallCrop.width)x\(smallCrop.height), bottom pixels only")
        print("PASS red VIP badge probe: compact red badge masked, white VIP title pixels retained")
        print("PASS OCR boundaries: single-frame noise ignored, repeated change accepted, pause immediate, stale identity expires")
        print("PASS system metadata: source-aware keys, opaque IDs, source matching, and system-player priority")
        print("PASS legacy TrackEntry JSON: optional source metadata decodes as nil")
    }

    @MainActor
    private static func verifyRedBadgeMask(_ observer: PlayerObserver) throws {
        let image = try makeRedBadgeImage(width: 400, height: 80)
        guard let masked = observer.suppressRedBadgePixels(from: image) else {
            throw ProbeFailure("production red badge mask returned nil for a valid image")
        }

        let sourcePixels = try rgbaPixels(image)
        let maskedPixels = try rgbaPixels(masked)
        let sourceRed = sourcePixels.filter { pixel in
            let red = Int(pixel.red)
            return red >= 150 && red > Int(pixel.green) + 55 && red > Int(pixel.blue) + 55
        }.count
        let maskedRed = maskedPixels.filter { pixel in
            let red = Int(pixel.red)
            return red >= 150 && red > Int(pixel.green) + 55 && red > Int(pixel.blue) + 55
        }.count
        try require(sourceRed > 0, "red badge fixture has no saturated-red pixels")
        try require(maskedRed == 0, "saturated-red badge pixels remained in OCR input")

        // The white block in the metadata region represents a legitimate song
        // title containing the word VIP. It must survive the image mask.
        let retainedWhite = maskedPixels.enumerated().filter { index, pixel in
            let x = index % image.width
            let y = index / image.width
            return x >= 145 && x < 175 && y >= 8 && y < 20 && pixel.red >= 220 && pixel.green >= 220 && pixel.blue >= 220
        }.count
        try require(retainedWhite > 0, "white VIP title pixels were removed with the badge")
        let changedWhite = maskedPixels.enumerated().filter { index, pixel in
            let x = index % image.width
            let y = index / image.width
            guard x >= 145 && x < 175 && y >= 8 && y < 20 else { return false }
            let source = sourcePixels[index]
            return pixel.red != source.red || pixel.green != source.green || pixel.blue != source.blue || pixel.alpha != source.alpha
        }.count
        try require(changedWhite == 0, "white VIP title pixels changed during red badge preprocessing")

        let sourceTop = sourcePixels[5 * image.width + 10]
        let sourceBottom = sourcePixels[image.width * (image.height - 6) + 10]
        let maskedTop = maskedPixels[5 * image.width + 10]
        let maskedBottom = maskedPixels[image.width * (image.height - 6) + 10]
        try require(maskedTop.red == sourceTop.red && maskedTop.green == sourceTop.green && maskedTop.blue == sourceTop.blue,
                    "red badge preprocessing flipped the image's vertical direction")
        try require(maskedBottom.red == sourceBottom.red && maskedBottom.green == sourceBottom.green && maskedBottom.blue == sourceBottom.blue,
                    "red badge preprocessing changed the lower playback bar direction")
    }

    @MainActor
    private static func verifyOCRStability() throws {
        let observer = PlayerObserver(bundleIdentifiers: [])
        var changedTitles: [String] = []
        var paused = false
        observer.eventHandler = { event in
            if case .trackChanged(let value) = event { changedTitles.append(value.title ?? "") }
            if case .playbackStateChanged(.paused) = event { paused = true }
        }
        func read(_ title: String?, _ time: Double, _ state: PlayerPlaybackState = .playing) {
            observer.publishStableOCR(PlayerSnapshot(
                trackID: nil, trackURL: nil, title: title, artist: "Artist", album: nil,
                currentTime: nil, duration: nil, playbackState: state,
                observedAt: Date(timeIntervalSince1970: time)
            ))
        }
        read("A", 0)
        try require(observer.snapshot == nil, "first OCR frame must await confirmation")
        observer.publishSnapshot(nil) // Empty AX polling between the two OCR reads.
        read("A", 1)
        try require(observer.snapshot?.title == "A", "empty AX polling erased the initial OCR candidate")
        read("B", 2)
        read("A", 3)
        try require(changedTitles == ["A"], "one noisy OCR frame split the recording")
        read("B", 4)
        read("B", 5)
        try require(changedTitles == ["A", "B"], "a repeated new title did not create exactly one boundary")
        read("C", 6, .paused)
        try require(paused && observer.snapshot?.title == "B", "pending identity delayed pause or replaced accepted identity")
        try require(observer.snapshot?.observedAt == Date(timeIntervalSince1970: 5), "pending OCR refreshed old identity")
        read("D", 7)
        try require(observer.snapshot?.playbackState == .paused, "unconfirmed new title resumed recording under the old identity")
        read("E", 9)
        try require(observer.snapshot?.observedAt == Date(timeIntervalSince1970: 5), "persistent OCR noise prevented identity expiration")
        read("E", 10)
        try require(changedTitles == ["A", "B", "E"], "stable identity did not recover after noise")
        read(nil, 11)
        read(nil, 12)
        try require(observer.snapshot?.title == "E" && observer.snapshot?.observedAt == Date(timeIntervalSince1970: 10), "missing title replaced or refreshed accepted identity")
    }

    @MainActor
    private static func verifySystemMetadata() throws {
        let observer = PlayerObserver(bundleIdentifiers: [])
        let opaqueID = "7B5C5A4E-0A8C-4D6A-9A09-2F8D2A4D0F51"

        func makeSnapshot(bundle: String, process: Int32, opaque: String) -> PlayerSnapshot {
            observer.makeSystemSnapshot(SystemPlayerState(
                title: "同名歌曲",
                artist: "同名艺人",
                duration: 180,
                currentTime: 12,
                playing: true,
                bundleIdentifier: bundle,
                processIdentifier: process,
                contentItemIdentifier: opaque
            ))
        }

        let base = makeSnapshot(bundle: "com.example.player-a", process: 401, opaque: opaqueID)
        let otherApp = makeSnapshot(bundle: "com.example.player-b", process: 401, opaque: opaqueID)
        let otherProcess = makeSnapshot(bundle: "com.example.player-a", process: 402, opaque: opaqueID)
        let otherItem = makeSnapshot(bundle: "com.example.player-a", process: 401, opaque: "opaque-item-2")
        let keys = Set([base.candidateKey, otherApp.candidateKey, otherProcess.candidateKey, otherItem.candidateKey])
        try require(keys.count == 4, "same title from another app, PID, or opaque item must create a new candidate key")

        try require(base.trackID == nil && base.neteaseID == nil && base.trackURL == nil,
                    "system opaque identity must not become a NetEase track ID or URL")
        try require(base.systemItemIdentifier == opaqueID, "system opaque identity was not retained")
        try require(base.candidateKey.contains("system-item:\(opaqueID)"), "candidate key omitted the system opaque identity")
        try require(!base.candidateKey.contains("netease-id:"), "candidate key treated the opaque identity as a NetEase ID")

        try require(base.matchesSource(bundleIdentifier: "com.example.player-a", processIdentifier: 401),
                    "matching source bundle and PID was rejected")
        try require(!base.matchesSource(bundleIdentifier: "com.example.player-b", processIdentifier: 401),
                    "mismatched source bundle was accepted")
        try require(!base.matchesSource(bundleIdentifier: "com.example.player-a", processIdentifier: 402),
                    "mismatched source PID was accepted")

        let earlier = PlayerSnapshot(
            trackID: nil, trackURL: nil, title: "同名歌曲", artist: "同名艺人", album: nil,
            currentTime: 12, duration: 180, playbackState: .playing,
            observedAt: Date(timeIntervalSince1970: 100),
            metadataSource: .systemPlayer,
            sourceBundleIdentifier: "com.example.player-a",
            sourceApplicationName: "Example Player",
            sourceProcessIdentifier: 401,
            systemItemIdentifier: opaqueID
        )
        let refreshed = PlayerSnapshot(
            trackID: nil, trackURL: nil, title: "同名歌曲", artist: "同名艺人", album: nil,
            currentTime: 12, duration: 180, playbackState: .playing,
            observedAt: Date(timeIntervalSince1970: 200),
            metadataSource: .systemPlayer,
            sourceBundleIdentifier: "com.example.player-a",
            sourceApplicationName: "Example Player",
            sourceProcessIdentifier: 401,
            systemItemIdentifier: opaqueID
        )
        try require(earlier == refreshed, "observation time alone changed PlayerSnapshot equality")

        observer.publishSnapshot(base)
        observer.systemSnapshot = base
        observer.publishStableOCR(PlayerSnapshot(
            trackID: nil, trackURL: nil, title: "错误 OCR", artist: "错误艺人", album: nil,
            currentTime: nil, duration: nil, playbackState: .playing,
            metadataSource: .screenOCR, sourceBundleIdentifier: "com.example.player-a",
            sourceProcessIdentifier: 401
        ))
        try require(observer.snapshot == base, "OCR candidate replaced a fresher system-player snapshot")
    }

    private static func verifyLegacyTrackDecode() throws {
        let legacyJSON = Data("""
        {
            "id":"E9C7D8A3-15C4-4B74-9EF6-1D31C9A7B3FA",
            "title":"旧记录",
            "artist":"旧艺人",
            "capturedSeconds":0,
            "isFull":false,
            "processingState":"播放处理未知",
            "source":"本地导入",
            "importedAt":0,
            "sourceOrder":0,
            "comparisonAllowed":true
        }
        """.utf8)
        let track = try JSONDecoder().decode(TrackEntry.self, from: legacyJSON)
        try require(track.sourceBundleIdentifier == nil && track.sourceApplicationName == nil && track.metadataSource == nil,
                    "legacy TrackEntry JSON invented or failed to default source metadata")
    }

    private enum PixelColor: Equatable {
        case red
        case blue
        case other
    }

    private static func makeSplitImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let color: (UInt8, UInt8, UInt8) = row < height / 2 ? (255, 0, 0) : (0, 0, 255)
            for column in 0..<width {
                let offset = (row * width + column) * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ProbeFailure("could not create split-color CGImage")
        }
        return image
    }

    private static func makeRedBadgeImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let isBadgeBorder = (column == 100 || column == 129) && row >= 30 && row < 50 ||
                    (row == 30 || row == 49) && column >= 100 && column < 130
                let isBadgeText = (column >= 107 && column < 111 || column >= 115 && column < 119 || column >= 123 && column < 127) &&
                    row >= 35 && row < 45
                let isWhiteTitle = column >= 145 && column < 175 && row >= 8 && row < 20
                let background: (UInt8, UInt8, UInt8) = row < height / 2 ? (28, 28, 32) : (60, 60, 68)
                let color: (UInt8, UInt8, UInt8) = isWhiteTitle
                    ? (245, 245, 245)
                    : isBadgeBorder || isBadgeText ? (220, 40, 50) : background
                let offset = (row * width + column) * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ProbeFailure("could not create red badge CGImage")
        }
        return image
    }

    private struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private static func rgbaPixels(_ image: CGImage) throws -> [RGBA] {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            throw ProbeFailure("image has no readable pixel data")
        }
        let count = CFDataGetLength(data) / 4
        return (0..<count).map { index in
            let offset = index * 4
            return RGBA(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    private static func pixelColors(_ image: CGImage) throws -> [PixelColor] {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            throw ProbeFailure("cropped image has no readable pixel data")
        }
        let count = CFDataGetLength(data) / 4
        return (0..<count).map { index in
            let offset = index * 4
            if bytes[offset] == 255 && bytes[offset + 1] == 0 && bytes[offset + 2] == 0 { return .red }
            if bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 2] == 255 { return .blue }
            return .other
        }
    }
}

private struct ProbeFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProbeFailure(message) }
}

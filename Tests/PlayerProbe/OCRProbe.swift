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

        print("PASS production OCR crop probe: normal=\(cropped.width)x\(cropped.height), small=\(smallCrop.width)x\(smallCrop.height), bottom pixels only")
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

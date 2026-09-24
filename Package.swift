// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Resonance",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Resonance", targets: ["ResonanceApp"])],
    targets: [
        .target(name: "ResonanceCore", linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "ResonanceApp", dependencies: ["ResonanceCore"], resources: [.copy("Resources")], linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("CoreAudio"), .linkedFramework("ApplicationServices"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("Vision")]),
        .testTarget(name: "ResonanceCoreTests", dependencies: ["ResonanceCore"])
    ],
    swiftLanguageVersions: [.v5]
)

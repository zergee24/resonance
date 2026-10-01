import Darwin
import Foundation

// Exercises the production artifact codec without opening the application or
// its database. Small synthetic PSDs expose temporary-object accumulation in a
// long synchronous batch; measurements are observations, not a machine limit.
@main
struct ArtifactMemoryVerification {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resonance-artifact-memory-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.plist.lzfse")
        let output = directory.appendingPathComponent("output.plist.lzfse")
        let iterations = 8
        let frames = 128
        let bins = 2_049
        // Preparation is outside the observed batch and its pool is drained.
        try autoreleasepool {
            var fixture: [SpectrumFrame] = []
            for frame in 0..<frames {
                var channels: [[Double]] = []
                for channel in 0..<2 {
                    var values: [Double] = []
                    for bin in 0..<bins {
                        let small = Double((frame * 13 + channel * 7 + bin) % 31) * 0.000001
                        values.append(small + sin(Double(bin + frame) / 17) * 0.0001 + 0.001)
                    }
                    channels.append(values)
                }
                fixture.append(SpectrumFrame(startTimeSeconds: Double(frame) * 0.04, sampleCount: 4_096,
                                             powerSpectralDensityByChannel: channels))
            }
            try LocalStore.writeArtifact(fixture, to: input)
        }
        var observations: [UInt64] = [residentBytes()]
        for _ in 0..<iterations {
            try roundTrip(input: input, output: output, frames: frames, bins: bins)
            observations.append(residentBytes())
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = [
            "iterations": iterations, "frames": frames, "bins": bins, "channels": 2,
            "residentBytesAfterEachIteration": observations,
            "peakResidentBytes": usage.ru_maxrss,
            "status": "PASS exact round trips and digest stability"
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    @inline(never)
    static func roundTrip(input: URL, output: URL, frames: Int, bins: Int) throws {
        let decoded = try LocalStore.readArtifact([SpectrumFrame].self, from: input)
        guard decoded.count == frames, decoded.allSatisfy({ $0.powerSpectralDensityByChannel.count == 2 && $0.powerSpectralDensityByChannel.allSatisfy { $0.count == bins } }) else {
            throw NSError(domain: "ArtifactMemoryVerification", code: 1)
        }
        try LocalStore.writeArtifact(decoded, to: output)
        let reread = try LocalStore.readArtifact([SpectrumFrame].self, from: output)
        guard reread == decoded, try LocalStore.audioDigest(input) == LocalStore.audioDigest(output) else {
            throw NSError(domain: "ArtifactMemoryVerification", code: 2)
        }
    }
}

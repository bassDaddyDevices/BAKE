import AVFAudio
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// A fresh folder for one test. Remove it with `defer`.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("BakeRenderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testUUID(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
}

let sourceAsset = AssetID(testUUID(9_000))

enum TestAudio {
    /// Deterministic test signal: a different sine per channel plus a little seeded noise. Peak stays below 0.6.
    static func samples(frames: Int, channels: Int) -> [[Float]] {
        var seed: UInt32 = 12_345
        return (0..<channels).map { channel in
            (0..<frames).map { frame in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(seed >> 8) / Float(1 << 24) - 0.5
                return Float(sin(Double(frame) * 0.05 * Double(channel + 1))) * 0.5 + noise * 0.02
            }
        }
    }

    static func write(
        _ samples: [[Float]], to url: URL, sampleRate: Double, bitDepth: Int = 32, isFloat: Bool = true
    ) throws {
        let frames = samples.first?.count ?? 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: samples.count,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for (index, channel) in samples.enumerated() {
            channel.withUnsafeBufferPointer { channels[index].update(from: $0.baseAddress!, count: frames) }
        }
        try file.write(from: buffer)
        file.close()
    }

    struct Decoded {
        let samples: [[Float]]
        let sampleRate: Double
        let bitDepth: Int?
        let isFloat: Bool?
    }

    /// Reads the whole file. A single `read(into:)` may return fewer frames than asked for, so loop.
    static func read(_ url: URL) throws -> Decoded {
        let file = try AVAudioFile(forReading: url)
        let channelCount = Int(file.processingFormat.channelCount)
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var samples = [[Float]](repeating: [], count: channelCount)
        while file.framePosition < file.length {
            try file.read(into: chunk)
            guard chunk.frameLength > 0 else { break }
            let data = try #require(chunk.floatChannelData)
            for channel in 0..<channelCount {
                samples[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(chunk.frameLength)))
            }
        }
        let settings = file.fileFormat.settings
        return Decoded(
            samples: samples,
            sampleRate: file.fileFormat.sampleRate,
            bitDepth: settings[AVLinearPCMBitDepthKey] as? Int,
            isFloat: settings[AVLinearPCMIsFloatKey] as? Bool
        )
    }

    static func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
    }
}

/// Builds small render graphs. Nodes get sequential IDs in creation order.
struct TestProject {
    var project = ProjectFile()
    private var nextNumber = 1

    @discardableResult
    mutating func add(_ kind: NodeKind, _ parameters: [ParameterID: ParameterValue] = [:], asset: AssetID? = nil) -> NodeID {
        let id = NodeID(testUUID(nextNumber))
        nextNumber += 1
        project.nodes.append(Node(id: id, kind: kind, parameters: parameters, assetID: asset))
        return id
    }

    /// Like `add`, with Page 2 parameters ticked so their `mod.<id>` pins exist.
    @discardableResult
    mutating func add(_ kind: NodeKind, _ parameters: [ParameterID: ParameterValue], modulated: [ParameterID]) -> NodeID {
        let id = NodeID(testUUID(nextNumber))
        nextNumber += 1
        project.nodes.append(Node(id: id, kind: kind, parameters: parameters, modulated: modulated))
        return id
    }

    mutating func connect(_ source: NodeID, to target: NodeID, _ pin: PinID = "in") {
        project.edges.append(Edge(from: PinRef(node: source, pin: "out"), to: PinRef(node: target, pin: pin)))
    }
}

/// Reads each asset's metadata and compiles, the way the app will before a bake.
func compile(_ project: ProjectFile, assetURLs: [AssetID: URL]) throws -> RenderPlan {
    try GraphCompiler.compile(project, assets: AssetInfoReader.infos(for: assetURLs))
}

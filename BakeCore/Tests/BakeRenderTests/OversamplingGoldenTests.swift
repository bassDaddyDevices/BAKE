import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of every oversampled node at 1–32x, so raising the oversampling ceiling (or any
/// later change to the shared oversampler) can never alter what a saved patch already sounds like (D-019).
///
/// A hash is FNV-1a over the bit patterns of every printed sample. To (re)record: set `expected` to `[:]`,
/// run this test once, and paste the dictionary literal it reports. Hashes come from the machine that
/// records them (libm differs across platforms), so record on the Mac that runs the suite.
@Suite(.serialized)
struct OversamplingGoldenTests {
    private static let kinds: [NodeKind] = [.distortion, .waveshaper, .wavefolder, .derivativeDistortion, .adaptiveClipping]
    private static let factors = [1, 2, 4, 8, 16, 32]

    /// "kind/factor": hash. Empty until recorded.
    private static let expected: [String: String] = [
        "distortion/1": "1c290165422d1d1c",
        "distortion/2": "ed077486605a1907",
        "distortion/4": "212a9d21441bb354",
        "distortion/8": "f4f93fc9a79ef708",
        "distortion/16": "b3b444449af932e2",
        "distortion/32": "51ae8de6c606968b",
        "waveshaper/1": "c22ad5061a6852b4",
        "waveshaper/2": "4197844556722b05",
        "waveshaper/4": "95caa0ccde63232f",
        "waveshaper/8": "f9a011a4eafc0d28",
        "waveshaper/16": "2f3a932160476e12",
        "waveshaper/32": "4f5b31ec1b47f007",
        "wavefolder/1": "c187cfca76fedcdd",
        "wavefolder/2": "ebc96633a07ce9ef",
        "wavefolder/4": "277b7ee7865b6788",
        "wavefolder/8": "45dbd0f713a7457a",
        "wavefolder/16": "19da457084f71c0b",
        "wavefolder/32": "84ad1b1546fed546",
        "derivativeDistortion/1": "fcc7b2df2f873d82",
        "derivativeDistortion/2": "7047aee8dd2571ab",
        "derivativeDistortion/4": "1e999231ecb79dc",
        "derivativeDistortion/8": "fdc13cd54ba2ae3e",
        "derivativeDistortion/16": "8f572acb3b8dbced",
        "derivativeDistortion/32": "960963f9c97142dd",
        "adaptiveClipping/1": "aff03f9825ea7522",
        "adaptiveClipping/2": "d7abc5fba36163bb",
        "adaptiveClipping/4": "9c07ab162adff0b1",
        "adaptiveClipping/8": "2295bd21112eb352",
        "adaptiveClipping/16": "dd55673584ded4ef",
        "adaptiveClipping/32": "1388eee5fa704686",
    ]

    private func render(
        _ kind: NodeKind, factor: Int? = nil, overrides: [String: ParameterValue] = [:], _ samples: [[Float]],
        workers: Int? = nil, chunk: Int = 65_536
    ) async throws -> [[Float]] {
        await CoreCountGate.shared.acquire()
        Parallel.overrideCoreCount(workers)
        defer {
            Parallel.overrideCoreCount(nil)
            CoreCountGate.shared.releaseSoon()
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(samples, to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        var parameters = NodeCatalog.defaultParameters(for: kind)
        if let factor { parameters["oversampling"] = .choice(String(factor)) }
        for (id, value) in overrides { parameters[id] = value }
        let node = graph.add(kind, parameters)
        let print = graph.add(.print, ["bitDepth": .choice("32f")])
        graph.connect(audio, to: node)
        graph.connect(node, to: print)
        let urls = [sourceAsset: source]
        let request = RenderRequest(
            plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: chunk
        )
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[print])).samples
    }

    private static func hash(_ channels: [[Float]]) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for channel in channels {
            for sample in channel {
                var bits = sample.bitPattern
                for _ in 0..<4 {
                    value = (value ^ UInt64(bits & 0xff)) &* 0x100000001b3
                    bits >>= 8
                }
            }
        }
        return String(value, radix: 16)
    }

    @Test func oversampledNodesKeepTheirExactOutput() async throws {
        let samples = TestAudio.samples(frames: 20_000, channels: 2)
        var found: [(String, String)] = []
        for kind in Self.kinds {
            for factor in Self.factors {
                let output = try await render(kind, factor: factor, samples)
                #expect(output.count == 2 && output.allSatisfy { $0.count == 20_000 && $0.allSatisfy { $0.isFinite } })
                found.append(("\(kind.rawValue)/\(factor)", Self.hash(output)))
            }
        }
        let wrong = found.filter { Self.expected[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }

    /// The ceiling is 256x (a 16,385-tap filter each way): every oversampled node must run there, stay
    /// finite, and still be chunk-invariant and identical on any number of cores.
    @Test(arguments: [NodeKind.distortion, .waveshaper, .wavefolder, .derivativeDistortion, .adaptiveClipping])
    func the256xCeilingIsFiniteAndDeterministic(kind: NodeKind) async throws {
        let samples = TestAudio.samples(frames: 3_000, channels: 2)
        let one = try await render(kind, factor: 256, samples, workers: 1)
        #expect(one.count == 2 && one.allSatisfy { $0.count == 3_000 && $0.allSatisfy { $0.isFinite } })
        #expect(one[0] != samples[0])
        #expect(try await render(kind, factor: 256, samples, workers: 8) == one)
        #expect(try await render(kind, factor: 256, samples, workers: 8, chunk: 777) == one)
    }

    // MARK: Old limits of the nodes whose ceilings are being raised

    private struct LegacyCase {
        let name: String
        let kind: NodeKind
        let overrides: [String: ParameterValue]
    }

    private static let legacyCases: [LegacyCase] = [
        .init(name: "granular/default", kind: .granularCloud, overrides: [:]),
        .init(name: "granular/atTheOldMaximum", kind: .granularCloud, overrides: [
            "size": .number(500), "density": .number(200), "spray": .number(2_000), "pitchSpread": .number(7),
            "reverse": .number(0.4), "stereoSpread": .number(1), "seed": .number(7),
        ]),
        .init(name: "granular/busy", kind: .granularCloud, overrides: [
            "size": .number(120), "density": .number(150), "spray": .number(300), "pitch": .number(-5), "seed": .number(3),
        ]),
        .init(name: "looper/sixtyFourPasses", kind: .looper, overrides: [
            "every": .number(1_000), "length": .number(30), "passes": .number(64), "shrink": .number(0.97),
            "pitchDrift": .number(0.2), "decay": .number(0.01),
        ]),
        .init(name: "looper/once", kind: .looper, overrides: [
            "mode": .choice("once"), "length": .number(40), "passes": .number(64), "start": .number(0.1),
        ]),
        .init(name: "stutter/sixtyFourRepeats", kind: .stutter, overrides: [
            "size": .number(20), "repeats": .number(64), "every": .number(600), "shrink": .number(0.98),
            "pitchDrift": .number(0.1), "jitter": .number(2), "seed": .number(11),
        ]),
    ]

    /// Frozen hashes of the cases above, taken before their ceilings were raised. Same recording rule as `expected`.
    private static let expectedLegacy: [String: String] = [
        "granular/default": "b164ce82a084c741",
        "granular/atTheOldMaximum": "22cbd70b0b378980",
        "granular/busy": "11a8142198d78860",
        "looper/sixtyFourPasses": "e7c82b6e2756c928",
        "looper/once": "46240bc45b4bc253",
        "stutter/sixtyFourRepeats": "50c64bb943e6c7ca",
    ]

    @Test func nodesKeepTheirExactOutputAtTheOldLimits() async throws {
        let samples = TestAudio.samples(frames: 48_000, channels: 2)
        var found: [(String, String)] = []
        for item in Self.legacyCases {
            let output = try await render(item.kind, overrides: item.overrides, samples)
            #expect(output.count == 2 && output.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isFinite } }, "\(item.name)")
            found.append((item.name, Self.hash(output)))
        }
        let wrong = found.filter { Self.expectedLegacy[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }

    /// Past the old limits: finite, and identical on any number of cores and in 777-frame chunks.
    @Test(arguments: [
        ("granular/dense", NodeKind.granularCloud, ["density": ParameterValue.number(1_000), "size": .number(2_000), "spray": .number(10_000), "pitchSpread": .number(5)]),
        ("granular/justPast200", .granularCloud, ["density": .number(260), "size": .number(500)]),
        ("looper/twoHundredPasses", .looper, ["every": .number(1_000), "length": .number(8), "passes": .number(200), "shrink": .number(0.995)]),
        ("stutter/twoHundredRepeats", .stutter, ["size": .number(6), "repeats": .number(200), "every": .number(500), "shrink": .number(0.995)]),
    ] as [(String, NodeKind, [String: ParameterValue])])
    func raisedCeilingsAreFiniteAndDeterministic(name: String, kind: NodeKind, overrides: [String: ParameterValue]) async throws {
        let samples = TestAudio.samples(frames: 24_000, channels: 2)
        let one = try await render(kind, overrides: overrides, samples, workers: 1)
        #expect(one.count == 2 && one.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isFinite } }, "\(name)")
        #expect(one[0] != samples[0], "\(name)")
        #expect(try await render(kind, overrides: overrides, samples, workers: 8) == one, "\(name)")
        #expect(try await render(kind, overrides: overrides, samples, workers: 8, chunk: 777) == one, "\(name)")
    }

    /// Density above 200 a second really does add grains: the cloud thickens, it doesn't just clamp.
    @Test func densityPast200AddsGrains() async throws {
        let samples = TestAudio.samples(frames: 24_000, channels: 1)
        let atCeiling = try await render(.granularCloud, overrides: ["density": .number(200), "size": .number(200)], samples)
        let past = try await render(.granularCloud, overrides: ["density": .number(800), "size": .number(200)], samples)
        #expect(atCeiling != past)
    }
}

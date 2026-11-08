import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Photo Booth through the session: the input captured once, cut at each trigger, and each chunk baked.
@MainActor
struct PhotoBoothBatchTests {
    private let access = PlainFileAccess()
    private let rate = 48_000.0

    private func reference(_ url: URL, writable: Bool) throws -> FileReference {
        FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
    }

    /// A 4 s mono groove: a different tone each half second, so every chunk can be told apart.
    private var groove: [Float] {
        (0..<192_000).map { i in Float(0.3 * sin(2 * .pi * (200 + 50 * Double(i / 24_000)) * Double(i) / rate)) }
    }

    private func write(_ signal: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.count)))
        buffer.frameLength = AVAudioFrameCount(signal.count)
        let data = try #require(buffer.floatChannelData)
        signal.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: signal.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// Audio (groove.wav) → Photo Booth (`parameters`, a Clock on Trigger if `clock`) → `after` → one Batch Bake
    /// (32f) per output of the last node, each into its own folder. Returns each folder's files and the folder.
    private func bake(
        _ parameters: [ParameterID: ParameterValue] = [:], clock: Bool = false, after: (NodeKind, [ParameterID: ParameterValue])? = nil
    ) async throws -> (outputs: [String: [URL]], folder: URL) {
        let folder = try makeTemporaryFolder()
        let source = folder.appending(path: "groove.wav")
        try write(groove, to: source)
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        project.assignAudio(path: source.path(percentEncoded: false), bookmark: nil, to: audio)
        let booth = project.addNode(.photoBooth, at: CanvasPoint())
        for (id, value) in parameters { project.setParameter(id, of: booth, to: value) }
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: booth, pin: "in"))
        if clock {
            let node = project.addNode(.clock, at: CanvasPoint())
            try project.connect(from: PinRef(node: node, pin: "out"), to: PinRef(node: booth, pin: "trigger"))
        }
        var last = booth
        if let (kind, settings) = after {
            last = project.addNode(kind, at: CanvasPoint())
            for (id, value) in settings { project.setParameter(id, of: last, to: value) }
            try project.connect(from: PinRef(node: booth, pin: "out"), to: PinRef(node: last, pin: "in"))
        }
        let pins = NodeCatalog.pins(of: try #require(project.node(last))).filter { $0.direction == .output }.map(\.id)
        for pin in pins {
            let out = folder.appending(path: pin, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let bake = project.addNode(.batchBake, at: CanvasPoint())
            project.setParameter("bitDepth", of: bake, to: .choice("32f"))
            project.setOutputFolder(try reference(out, writable: true), for: bake)
            try project.connect(from: PinRef(node: last, pin: pin), to: PinRef(node: bake, pin: "in"))
        }
        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        guard case .finished = session.state else {
            Issue.record("the bake failed: \(session.state)")
            return ([:], folder)
        }
        var outputs: [String: [URL]] = [:]
        for pin in pins {
            let out = folder.appending(path: pin, directoryHint: .isDirectory)
            outputs[pin] = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return (outputs, folder)
    }

    @Test func everyQuarterMakesEightChunksOfTheGroove() async throws {
        let (outputs, folder) = try await bake()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try #require(outputs["out"])
        #expect(files.map(\.lastPathComponent) == (1...8).map { "groove-00\($0).wav" })
        let original = groove
        for (index, url) in files.enumerated() {
            let chunk = try samples(url)[0]
            #expect(chunk.count == 24_000)
            // The chunk is that quarter of the groove, apart from its 2 ms (96-frame) fades.
            let start = index * 24_000
            #expect((96..<(24_000 - 96)).allSatisfy { abs(chunk[$0] - original[start + $0]) < 1e-6 }, "\(url.lastPathComponent)")
            #expect(chunk[0] == 0 && chunk[23_999] == 0)
        }
        // Nothing of the capture is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(Set(leftovers) == ["groove.wav", "out"])
    }

    @Test func aClockOnTriggerCutsTheSameChunksAsTheGrid() async throws {
        let (grid, one) = try await bake()
        defer { try? FileManager.default.removeItem(at: one) }
        let (clocked, two) = try await bake(clock: true)
        defer { try? FileManager.default.removeItem(at: two) }
        let a = try #require(grid["out"]), b = try #require(clocked["out"])
        #expect(a.count == 8 && b.count == 8)
        for (x, y) in zip(a, b) { #expect(try samples(x) == samples(y)) }
    }

    @Test func fixedChunksAreOneShotsAndAMerryGoRoundDealsThem() async throws {
        let (fixed, one) = try await bake(["length": .choice("fixed"), "fixedLength": .choice("1/16")])
        defer { try? FileManager.default.removeItem(at: one) }
        let shots = try #require(fixed["out"])
        #expect(shots.count == 8)
        #expect(try shots.allSatisfy { try samples($0)[0].count == 6_000 })

        let (dealt, two) = try await bake(after: (.merryGoRound, ["outputs": .choice("2")]))
        defer { try? FileManager.default.removeItem(at: two) }
        #expect(dealt["out1"]?.map(\.lastPathComponent) == ["groove-001.wav", "groove-003.wav", "groove-005.wav", "groove-007.wav"])
        #expect(dealt["out2"]?.map(\.lastPathComponent) == ["groove-002.wav", "groove-004.wav", "groove-006.wav", "groove-008.wav"])
    }
}

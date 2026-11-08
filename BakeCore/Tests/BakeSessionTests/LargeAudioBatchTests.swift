import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Large Audio Processor through the session: one long file, one baked file per slice.
@MainActor
struct LargeAudioBatchTests {
    private let access = PlainFileAccess()
    private let rate = 48_000.0

    private struct Setup {
        let folder: URL, output: URL, take: URL
        var project = ProjectFile()
        let slicer: NodeID, filters: NodeID, bake: NodeID
    }

    /// `take 1.wav`: 4 s of stereo silence with 20 ms bursts at 0.5, 1.2, 2.0 and 3.1 s;
    /// Large Audio Processor → Filters → Batch Bake (32-bit float) → out/.
    private func setup() throws -> Setup {
        let folder = try makeTemporaryFolder()
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let take = folder.appending(path: "take 1.wav")
        try writeClicks(at: [0.5, 1.2, 2.0, 3.1], seconds: 4, to: take)
        var project = ProjectFile()
        let slicer = project.addNode(.largeAudio, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.assignAudio(path: take.path(percentEncoded: false), bookmark: try access.bookmark(for: take, writable: false), to: slicer)
        try project.connect(from: PinRef(node: slicer, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.setParameter("bitDepth", of: bake, to: .choice("32f"))
        project.setOutputFolder(try reference(output, writable: true), for: bake)
        return Setup(folder: folder, output: output, take: take, project: project, slicer: slicer, filters: filters, bake: bake)
    }

    private func writeClicks(at times: [Double], seconds: Double, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<Int(frames) { data[channel][frame] = 0 }
            for time in times {
                let start = Int(time * rate)
                for frame in 0..<Int(0.02 * rate) where start + frame < Int(frames) {
                    data[channel][start + frame] = 0.5 * sin(2 * .pi * 1_000 * Float(frame) / Float(rate))
                }
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func reference(_ url: URL, writable: Bool) throws -> FileReference {
        FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
    }

    private func bake(_ project: ProjectFile) async -> BakeState {
        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        return session.state
    }

    @Test func eachSliceBakesItsOwnFileLikeBakingThatClipAlone() async throws {
        let setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        guard case .finished(let outputs) = await bake(setup.project) else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["take 1 001.wav", "take 1 002.wav", "take 1 003.wav", "take 1 004.wav"])
        // Each output is its clip through the same Filters, baked on its own.
        let parameters = NodeCatalog.resolvedParameters(of: try #require(setup.project.node(setup.slicer)))
        let clips = try SliceClips.clips(for: setup.take, parameters: parameters, in: BakeSession.sliceCache)
        #expect(clips.count == 4)
        for (clip, output) in zip(clips, outputs) {
            var project = ProjectFile()
            let audio = project.addNode(.audio, at: CanvasPoint())
            let filters = project.addNode(.filters, at: CanvasPoint())
            let print = project.addNode(.print, at: CanvasPoint())
            project.assignAudio(path: clip.path, bookmark: nil, to: audio)
            try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: filters, pin: "in"))
            try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: print, pin: "in"))
            project.setParameter("bitDepth", of: print, to: .choice("32f"))
            let alone = setup.folder.appending(path: "alone", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: alone, withIntermediateDirectories: true)
            project.setOutputFolder(try reference(alone, writable: true), for: print)
            project.setParameter("versions", of: print, to: .choice("overwrite"))
            guard case .finished(let single) = await bake(project), let url = single.first else {
                Issue.record("the single bake failed")
                continue
            }
            #expect(try samples(url) == samples(output), "\(output.lastPathComponent)")
        }
    }

    /// A folder of two impulse responses on a Batch Audio, into a Convolver with the slices: the shorter
    /// list starts over, so the IRs alternate across the four slices.
    @Test func aFolderOfImpulsesAlternatesAcrossTheSlices() async throws {
        var setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let irs = setup.folder.appending(path: "irs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: irs, withIntermediateDirectories: true)
        try writeSine(to: irs.appending(path: "a.wav"), seconds: 0.1)
        try writeSine(to: irs.appending(path: "b.wav"), seconds: 0.2)
        let source = setup.project.addNode(.batchAudio, at: CanvasPoint())
        let convolver = setup.project.addNode(.convolver, at: CanvasPoint())
        setup.project.setSourceFolder(try reference(irs, writable: false), for: source)
        let batchBake = setup.bake
        setup.project.edges.removeAll { $0.to.node == batchBake }
        try setup.project.connect(from: PinRef(node: setup.filters, pin: "out"), to: PinRef(node: convolver, pin: "in"))
        try setup.project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: convolver, pin: "ir"))
        try setup.project.connect(from: PinRef(node: convolver, pin: "out"), to: PinRef(node: setup.bake, pin: "in"))
        guard case .finished(let outputs) = await bake(setup.project) else {
            Issue.record("the batch failed")
            return
        }
        #expect(outputs.count == 4)
        let parameters = NodeCatalog.resolvedParameters(of: try #require(setup.project.node(setup.slicer)))
        let slices = try SliceClips.slices(for: setup.take, parameters: parameters, in: BakeSession.sliceCache)
        let irFrames = [Int(0.1 * rate), Int(0.2 * rate)]
        for (index, output) in outputs.enumerated() {
            // Convolver: input + impulse − 1 frames, the impulse alternating a, b, a, b.
            #expect(try samples(output)[0].count == slices[index].count + irFrames[index % 2] - 1, "\(output.lastPathComponent)")
        }
    }

    @Test func theCardCountsTheSlicesBeforeABake() async throws {
        let setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let session = BakeSession(access: access)
        await session.refreshAssetInfo(for: setup.project)
        #expect(session.batchFiles[setup.slicer]?.count == 4)
        let marks = try #require(session.sliceMarks[setup.slicer])
        #expect(marks.count == 4)
        for (mark, time) in zip(marks, [0.5, 1.2, 2.0, 3.1]) { #expect(abs(mark - time / 4) < 0.002) }
        #expect((session.assetInfo[BatchRun.assetID(of: setup.slicer, pass: 0)]?.frameCount ?? 0) > Int(0.6 * rate))
    }

    @Test func aSlicerWithoutAFileSaysSo() async throws {
        var setup = try setup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        let empty = setup.project.addNode(.largeAudio, at: CanvasPoint())
        let second = setup.project.addNode(.batchBake, at: CanvasPoint())
        try setup.project.connect(from: PinRef(node: empty, pin: "out"), to: PinRef(node: second, pin: "in"))
        guard case .failed(let issues) = await bake(setup.project) else {
            Issue.record("expected the batch to fail")
            return
        }
        #expect(issues.nodes[empty] == [BatchIssue.noFile(empty).message])
    }
}

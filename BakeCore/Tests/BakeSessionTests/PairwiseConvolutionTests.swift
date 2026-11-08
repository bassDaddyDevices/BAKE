import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Pairwise convolution as a patch: one carrier (Audio → Convolver) against a folder of impulse responses
/// (Batch Audio → the Convolver's IR) gives one file per response.
@MainActor
struct PairwiseConvolutionTests {
    private let access = PlainFileAccess()
    private let rate = 48_000.0

    private func reference(_ url: URL, writable: Bool) throws -> FileReference {
        FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
    }

    private func write(_ signal: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.count)))
        buffer.frameLength = AVAudioFrameCount(signal.count)
        let data = try #require(buffer.floatChannelData)
        signal.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: signal.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    private func bake(_ project: ProjectFile) async -> [URL] {
        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        guard case .finished(let outputs) = session.state else {
            Issue.record("the bake failed: \(session.state)")
            return []
        }
        return outputs
    }

    /// Audio (`carrier`) → Convolver ← `ir` (an Audio file, or a Batch Audio folder) → `output` (a Bake or Batch Bake).
    private func patch(carrier: URL, ir: URL, batch: Bool, into folder: URL) throws -> ProjectFile {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        project.assignAudio(path: carrier.path(percentEncoded: false), bookmark: nil, to: audio)
        let impulse = project.addNode(batch ? .batchAudio : .audio, at: CanvasPoint())
        if batch {
            project.setSourceFolder(try reference(ir, writable: false), for: impulse)
        } else {
            project.assignAudio(path: ir.path(percentEncoded: false), bookmark: nil, to: impulse)
        }
        let convolver = project.addNode(.convolver, at: CanvasPoint())
        let output = project.addNode(batch ? .batchBake : .print, at: CanvasPoint())
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: convolver, pin: "in"))
        try project.connect(from: PinRef(node: impulse, pin: "out"), to: PinRef(node: convolver, pin: "ir"))
        try project.connect(from: PinRef(node: convolver, pin: "out"), to: PinRef(node: output, pin: "in"))
        project.setParameter("bitDepth", of: output, to: .choice("32f"))
        if !batch { project.setParameter("prefix", of: output, to: .text(ir.deletingPathExtension().lastPathComponent)) }
        project.setOutputFolder(try reference(folder, writable: true), for: output)
        return project
    }

    @Test func oneCarrierAgainstAFolderGivesEachConvolution() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let irs = folder.appending(path: "irs", directoryHint: .isDirectory)
        let out = folder.appending(path: "out", directoryHint: .isDirectory)
        let alone = folder.appending(path: "alone", directoryHint: .isDirectory)
        for url in [irs, out, alone] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let carrier = folder.appending(path: "carrier.wav")
        try write((0..<9_600).map { Float(0.3 * sin(2 * .pi * 330 * Double($0) / rate)) }, to: carrier)
        for (name, decay) in [("hall", 4.0), ("plate", 12.0), ("room", 30.0)] {
            try write((0..<4_800).map { Float(exp(-Double($0) / rate * decay) * cos(Double($0) * 0.7)) }, to: irs.appending(path: "\(name).wav"))
        }

        let outputs = await bake(try patch(carrier: carrier, ir: irs, batch: true, into: out))
        #expect(outputs.map(\.lastPathComponent) == ["hall.wav", "plate.wav", "room.wav"])
        for url in outputs {
            let single = await bake(try patch(carrier: carrier, ir: irs.appending(path: url.lastPathComponent), batch: false, into: alone))
            #expect(try samples(url) == samples(#require(single.first)), "\(url.lastPathComponent)")
        }
    }
}

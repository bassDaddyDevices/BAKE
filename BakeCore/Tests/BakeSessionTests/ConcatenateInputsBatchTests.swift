import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Concatenate with two inputs in a batch: each pass contributes its inputs in pin order.
@MainActor
struct ConcatenateInputsBatchTests {
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

    @Test func eachFileThenItsReverseMakesSixClipsInOrder() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "in", directoryHint: .isDirectory)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        for url in [input, output] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        // Three different ramps, so every clip and its direction can be told apart.
        let clips: [(String, [Float])] = [("a", 1_000, 0.1), ("b", 1_500, 0.2), ("c", 700, 0.3)].map { name, frames, top in
            (name, (0..<frames).map { Float(top) * Float($0) / Float(frames) })
        }
        for (name, signal) in clips { try write(signal, to: input.appending(path: "\(name).wav")) }

        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let reverse = project.addNode(.reverse, at: CanvasPoint())
        let join = project.addNode(.concatenate, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        project.setSourceFolder(try reference(input, writable: false), for: source)
        project.setParameter("crossfade", of: join, to: .number(0))
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: join, pin: "in1"))
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: reverse, pin: "in"))
        try project.connect(from: PinRef(node: reverse, pin: "out"), to: PinRef(node: join, pin: "in2"))
        try project.connect(from: PinRef(node: join, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.setParameter("bitDepth", of: bake, to: .choice("32f"))
        project.setParameter("prefix", of: bake, to: .text("joined"))
        project.setOutputFolder(try reference(output, writable: true), for: bake)

        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        guard case .finished(let outputs) = session.state, let url = outputs.first else {
            Issue.record("the batch failed: \(session.state)")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["joined.wav"])
        let expected = clips.flatMap { $0.1 + $0.1.reversed() }
        let joined = try samples(url)[0]
        #expect(joined.count == expected.count)
        #expect(zip(joined, expected).allSatisfy { abs($0 - $1) < 1e-6 })
    }
}

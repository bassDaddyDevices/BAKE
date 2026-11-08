import AVFAudio
import BakeGraph
import BakeRender
import Foundation
import Testing
@testable import BakeSession

/// Batch Conform through the session: a folder of mixed loops to one tempo and key.
@MainActor
struct ConformBatchTests {
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

    /// A decaying 1 kHz burst every beat.
    private func beat(_ bpm: Double, seconds: Double) -> [Float] {
        let period = 60 / bpm * rate
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i).truncatingRemainder(dividingBy: period) / rate
            return Float(exp(-t * 60) * sin(2 * .pi * 1_000 * t) * 0.5)
        }
    }

    private func chord(_ hertz: [Double], seconds: Double = 2) -> [Float] {
        (0..<Int(seconds * rate)).map { i in Float(hertz.reduce(0) { $0 + sin(2 * .pi * $1 * Double(i) / rate) } * 0.2) }
    }

    @Test func aFolderOfMixedLoopsComesOutAtOneTempoAndKey() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "in", directoryHint: .isDirectory)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        for url in [input, output] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try write(beat(100, seconds: 4.8), to: input.appending(path: "drums 100bpm.wav"))  // named: 100 BPM
        try write(beat(140, seconds: 4), to: input.appending(path: "loop.wav"))  // detected: 140 BPM
        try write(chord([220, 261.63, 329.63]), to: input.appending(path: "pad Am.wav"))  // named: A minor, no beat
        try write(chord([293.66, 369.99, 440]), to: input.appending(path: "chord.wav"))  // detected: D major

        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let conform = project.addNode(.batchConform, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(try reference(input, writable: false), for: source)
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: conform, pin: "in"))
        try project.connect(from: PinRef(node: conform, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.setParameter("bitDepth", of: bake, to: .choice("32f"))
        project.setOutputFolder(try reference(output, writable: true), for: bake)

        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        guard case .finished(let outputs) = session.state else {
            Issue.record("the batch failed: \(session.state)")
            return
        }
        var files: [String: URL] = [:]
        for url in outputs { files[url.deletingPathExtension().lastPathComponent] = url }
        #expect(Set(files.keys) == ["drums 100bpm", "loop", "pad Am", "chord"])

        // Lengths: what 120 BPM implies. 100 → 120 makes 4.8 s into 4 s; 140 → 120 makes 4 s into about 4.67 s.
        let drums = try samples(#require(files["drums 100bpm"]))[0]
        #expect(abs(drums.count - 192_000) <= 1)
        let loop = try samples(#require(files["loop"]))[0]
        #expect(abs(Double(loop.count) / (4 * rate * 140 / 120) - 1) < 0.005)
        // And the stretched beats now read 120.
        #expect(abs((try ConformMeasure.measure(#require(files["drums 100bpm"]), target: 120, sampleRate: rate).bpm ?? 0) - 120) <= 1)

        // Keys: no beat, so no stretch; A minor +3 is C minor, D major −2 is C major.
        let pad = try #require(files["pad Am"]), chord = try #require(files["chord"])
        #expect(try samples(pad)[0].count == 96_000)
        #expect(try ConformMeasure.measure(pad, target: 120, sampleRate: rate).key == .init(root: 0, minor: true))
        #expect(try ConformMeasure.measure(chord, target: 120, sampleRate: rate).key == .init(root: 0, minor: false))
    }
}

import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Corpus Scatter and Ensemble Averager through the session: every pass captured, then combined into one file.
@MainActor
struct ScatterAverageBatchTests {
    private let access = PlainFileAccess()
    private let rate = 48_000.0

    private func reference(_ url: URL, writable: Bool) throws -> FileReference {
        FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
    }

    private func bake(_ project: ProjectFile) async -> BakeState {
        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        return session.state
    }

    /// A stereo file of `signal` in both channels.
    private func write(_ signal: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.count)))
        buffer.frameLength = AVAudioFrameCount(signal.count)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 { signal.withUnsafeBufferPointer { data[channel].update(from: $0.baseAddress!, count: signal.count) } }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// Batch Audio over `files` → `gather` (with `parameters`) → `after` → Bake (32-bit float) into out/.
    private func project(
        _ gather: NodeKind, _ parameters: [ParameterID: ParameterValue], files: [(String, [Float])], after: [NodeKind] = []
    ) throws -> (ProjectFile, folder: URL) {
        let folder = try makeTemporaryFolder()
        let input = folder.appending(path: "in", directoryHint: .isDirectory)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        for url in [input, output] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        for (name, signal) in files { try write(signal, to: input.appending(path: "\(name).wav")) }
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        project.setSourceFolder(try reference(input, writable: false), for: source)
        var last = source
        for kind in [gather] + after + [.print] {
            let node = project.addNode(kind, at: CanvasPoint())
            try project.connect(from: PinRef(node: last, pin: "out"), to: PinRef(node: node, pin: "in"))
            last = node
            if kind == gather { for (id, value) in parameters { project.setParameter(id, of: node, to: value) } }
        }
        project.setParameter("bitDepth", of: last, to: .choice("32f"))
        project.setParameter("prefix", of: last, to: .text("combined"))
        project.setOutputFolder(try reference(output, writable: true), for: last)
        return (project, folder)
    }

    private func outputs(_ project: ProjectFile) async throws -> [URL] {
        guard case .finished(let outputs) = await bake(project) else {
            Issue.record("the batch failed")
            return []
        }
        return outputs
    }

    private var sines: [(String, [Float])] {
        (0..<8).map { index in
            let hertz = 200.0 * pow(1.25, Double(index))
            return ("sine \(index)", (0..<4_800).map { Float(0.3 * sin(2 * .pi * hertz * Double($0) / rate)) })
        }
    }

    @Test func eightSinesScatterIntoOneTenSecondStereoFileTheSameEachTime() async throws {
        let (first, folder) = try project(.corpusScatter, ["duration": .number(10), "seed": .number(1)], files: sines)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = try await outputs(first)
        let again = try await outputs(first)
        #expect(one.count == 1 && again.count == 1)
        let audio = try samples(#require(one.first))
        #expect(audio.count == 2 && audio[0].count == 480_000)
        #expect(try audio == samples(#require(again.first)))

        let (other, otherFolder) = try project(.corpusScatter, ["duration": .number(10), "seed": .number(2)], files: sines)
        defer { try? FileManager.default.removeItem(at: otherFolder) }
        #expect(try audio != samples(#require(await outputs(other).first)))
    }

    /// A snare-like hit: a tone and seeded noise, decaying.
    private var snare: [Float] {
        var seed: UInt32 = 7
        return (0..<9_600).map { i in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) - 0.5
            let t = Double(i) / rate
            return Float(exp(-t * 25) * (0.5 * sin(2 * .pi * 180 * t) + 0.6 * noise))
        }
    }

    private func rms(_ signal: [Float]) -> Double {
        sqrt(signal.reduce(0) { $0 + Double($1 * $1) } / Double(max(signal.count, 1)))
    }

    @Test func fiveCopiesOfASnareAverageToTheSnareAtTheMeanGain() async throws {
        let files = [0.2, 0.4, 0.6, 0.8, 1.0].map { gain in ("snare \(gain)", snare.map { $0 * Float(gain) }) }
        let (project, folder) = try project(.ensembleAverager, ["mode": .choice("mean")], files: files)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputs = try await outputs(project)
        #expect(outputs.count == 1)
        let audio = try samples(#require(outputs.first))
        #expect(audio.count == 2 && audio[0].count == snare.count)
        let decibels = 20 * log10(rms(audio[0]) / (0.6 * rms(snare)))
        #expect(abs(decibels) < 0.5)
    }

    @Test func aReverbAfterEitherRendersOnce() async throws {
        let snares = [0.5, 1.0].map { gain in ("snare \(gain)", snare.map { $0 * Float(gain) }) }
        for (kind, files) in [(NodeKind.corpusScatter, sines), (.ensembleAverager, snares)] {
            let (project, folder) = try project(kind, ["duration": .number(2)], files: files, after: [.reverb])
            defer { try? FileManager.default.removeItem(at: folder) }
            #expect(try await outputs(project).count == 1, "\(kind)")
        }
    }
}

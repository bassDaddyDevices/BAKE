import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

/// Combinatorial Matrix through the session: one file per combination, each its layers' sum.
@MainActor
struct MatrixBatchTests {
    private let access = PlainFileAccess()
    private let rate = 48_000.0

    private func reference(_ url: URL, writable: Bool) throws -> FileReference {
        FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: try access.bookmark(for: url, writable: writable))
    }

    /// A mono file of `signal`.
    private func write(_ signal: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.count)))
        buffer.frameLength = AVAudioFrameCount(signal.count)
        let data = try #require(buffer.floatChannelData)
        signal.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: signal.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    private func tone(_ hertz: Double, level: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(level * sin(2 * .pi * hertz * Double($0) / rate)) }
    }

    @Test func twoByThreeFoldersMakeSixFilesEachTheSumOfItsLayers() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clicks = folder.appending(path: "clicks", directoryHint: .isDirectory)
        let subs = folder.appending(path: "subs", directoryHint: .isDirectory)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        for url in [clicks, subs, output] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let a = ["c1": tone(2_000, level: 0.1, frames: 2_400), "c2": tone(3_000, level: 0.1, frames: 1_200)]
        let b = ["s1": tone(50, level: 0.2, frames: 4_800), "s2": tone(60, level: 0.2, frames: 4_800), "s3": tone(70, level: 0.2, frames: 3_600)]
        for (name, signal) in a { try write(signal, to: clicks.appending(path: "\(name).wav")) }
        for (name, signal) in b { try write(signal, to: subs.appending(path: "\(name).wav")) }

        var project = ProjectFile()
        let left = project.addNode(.batchAudio, at: CanvasPoint())
        let right = project.addNode(.batchAudio, at: CanvasPoint())
        let matrix = project.addNode(.combinatorialMatrix, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(try reference(clicks, writable: false), for: left)
        project.setSourceFolder(try reference(subs, writable: false), for: right)
        try project.connect(from: PinRef(node: left, pin: "out"), to: PinRef(node: matrix, pin: "a"))
        try project.connect(from: PinRef(node: right, pin: "out"), to: PinRef(node: matrix, pin: "b"))
        try project.connect(from: PinRef(node: matrix, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.setParameter("align", of: matrix, to: .choice("start"))
        project.setParameter("bitDepth", of: bake, to: .choice("32f"))
        project.setOutputFolder(try reference(output, writable: true), for: bake)

        let session = BakeSession(access: access)
        session.bake(project, embedWorkflow: false)
        await session.waitUntilFinished()
        guard case .finished(let outputs) = session.state else {
            Issue.record("the batch failed: \(session.state)")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["c1+s1.wav", "c1+s2.wav", "c1+s3.wav", "c2+s1.wav", "c2+s2.wav", "c2+s3.wav"])
        for url in outputs {
            let names = url.deletingPathExtension().lastPathComponent.split(separator: "+").map(String.init)
            let (click, sub) = (try #require(a[names[0]]), try #require(b[names[1]]))
            let audio = try samples(url)[0]
            #expect(audio.count == max(click.count, sub.count))
            let error = audio.indices.map { i in
                abs(audio[i] - ((i < click.count ? click[i] : 0) + (i < sub.count ? sub[i] : 0)))
            }.max() ?? 1
            #expect(error < 1e-6, "\(url.lastPathComponent)")
        }
    }
}

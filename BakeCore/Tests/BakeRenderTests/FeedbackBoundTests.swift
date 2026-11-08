import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Spec §11: the saturation bound keeps any loop finite, at default Drive too (review, 2026-10-28).
struct FeedbackBoundTests {
    @Test(arguments: [0.0, 6.0]) func aLoudLoopAtPlusSixDecibelsStaysBounded(drive: Double) async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.wav")
        let sine = (0..<24_000).map { Float(0.9 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        try TestAudio.write([sine], to: src, sampleRate: 48_000)
        var g = TestProject()
        let a = g.add(.audio, asset: sourceAsset)
        let f = g.add(.feedback, ["gain": .number(6), "drive": .number(drive), "tail": .number(1)])
        let m = g.add(.mixer)
        let b = g.add(.print, ["bitDepth": .choice("32f")])
        g.connect(a, to: f); g.connect(f, to: m, "in1"); g.connect(m, to: f, "return"); g.connect(f, to: b)
        let out = dir.appendingPathComponent("o", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = [sourceAsset: src]
        let r = try await RenderEngine.render(RenderRequest(plan: try compile(g.project, assetURLs: urls), assetURLs: urls, outputDirectory: out))
        let s = try TestAudio.read(try #require(r.outputs[b])).samples[0]
        #expect(s.allSatisfy { $0.isFinite })
        // |out| <= |in| + 1: the return is bounded by 1 / driveGain <= 1.
        for (frame, value) in s.enumerated() {
            let input = frame < sine.count ? abs(sine[frame]) : 0
            #expect(abs(value) <= input + 1 + 1e-6, "frame \(frame)")
            if abs(value) > input + 1 + 1e-6 { break }
        }
    }
}

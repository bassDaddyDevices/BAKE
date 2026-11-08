import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Level, notch depth, stereo and chunking checks through the engine (Claude's review, 2026-10-27).
struct FractalFilterLevelTests {
    func noise(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<n).map { _ in s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: s) >> 40) / Float(1 << 23) * 0.5 }
    }

    func render(_ channels: [[Float]], _ p: [ParameterID: ParameterValue], chunk: Int = 65_536) async throws -> [[Float]] {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.wav")
        try TestAudio.write(channels, to: src, sampleRate: 48_000)
        var g = TestProject()
        let a = g.add(.audio, asset: sourceAsset)
        let f = g.add(.fractalFilter, p)
        let b = g.add(.print, ["bitDepth": .choice("32f")])
        g.connect(a, to: f); g.connect(f, to: b)
        let out = dir.appendingPathComponent("o", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = [sourceAsset: src]
        let r = try await RenderEngine.render(RenderRequest(plan: try compile(g.project, assetURLs: urls), assetURLs: urls, outputDirectory: out, chunkFrames: chunk))
        return try TestAudio.read(try #require(r.outputs[b])).samples
    }

    func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)) }

    @Test func stereoWithIdenticalChannelsComesOutIdentical() async throws {
        let n = noise(96_000, seed: 3)
        for pattern in ["cantor", "mandelbrot", "julia", "koch"] {
            let out = try await render([n, n], ["pattern": .choice(pattern), "iterations": .number(8), "q": .number(20)])
            let worst = zip(out[0], out[1]).map { abs($0 - $1) }.max()!
            #expect(worst == 0)
        }
    }

    @Test func whiteNoiseKeepsItsLevelWithin4dB() async throws {
        let n = noise(96_000, seed: 7)
        let inRMS = rms(n[12_000..<84_000])
        for pattern in ["cantor", "mandelbrot", "julia", "koch"] {
            for depth in [1.0, 8, 16] {
                let out = try await render([n], ["pattern": .choice(pattern), "iterations": .number(depth)])[0]
                let db = 20 * log10(rms(out[12_000..<84_000]) / inRMS)
                // Each STFT frame keeps its energy; sparse masks (deep Cantor) lose up to ~3.5 dB in overlap-add.
                #expect(abs(db) < 4, "\(pattern) depth \(depth): \(db) dB")
            }
        }
    }

    @Test func cantorDepthOneNotchIsFloorTimesResonance() async throws {
        // x in [1/6, 1/3) and (2/3, 5/6] are notched; compare band energy at x = 0.25 and 0.75 with x = 0.05 and 0.5.
        let n = noise(192_000, seed: 11)
        let out = try await render([n], ["pattern": .choice("cantor"), "iterations": .number(1), "q": .number(0.1), "fftSize": .choice("4096")])[0]
        func freq(_ x: Double) -> Double { 20 * pow(24_000.0 / 20, x) }
        func power(_ s: [Float], _ f: Double) -> Double {   // Goertzel over 1 s
            let w = 2 * Double.pi * f / 48_000; var a = 0.0, b = 0.0
            for v in s[48_000..<144_000] { let c = Double(v) + 2 * cos(w) * a - b; b = a; a = c }
            return a * a + b * b - 2 * cos(w) * a * b
        }
        func ratio(_ x: Double) -> Double {
            // average a few nearby frequencies to beat noise variance
            let fs = (0..<9).map { freq(x) * (1 + 0.004 * Double($0 - 4)) }
            let o = fs.map { power(out, $0) }.reduce(0, +), i = fs.map { power(n, $0) }.reduce(0, +)
            return 10 * log10(o / i)
        }
        // u = fract(2|x - 0.5|) must avoid ternary digit 1 in all five levels to stay open:
        // x = 0.5 (u = 0) is open; x = 0.25 (u = 0.5, first digit 1) is notched.
        let open = [0.5].map(ratio), notched = [0.25, 0.75].map(ratio)
        // Notched = floor 0.03 x resonance peak 4 at x = 0.25 and 0.75: 20 log10(1 / 0.12) = 18.4 dB below open.
        let depth = open.min()! - notched.max()!
        #expect(abs(depth - 18.4) < 1.5, "notch depth \(depth) dB")
    }

    @Test func chunk777MatchesOneChunk() async throws {
        let n = noise(48_000, seed: 5)
        let p: [ParameterID: ParameterValue] = ["pattern": .choice("julia"), "iterations": .number(12), "phaseMode": .choice("randomized")]
        let whole = try await render([n], p)[0], chunked = try await render([n], p, chunk: 777)[0]
        let worst = zip(whole, chunked).map { abs($0 - $1) }.max()!
        #expect(worst <= 1e-6)
    }
}

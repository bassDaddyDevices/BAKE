import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Owner report (2026-10-27): Spectral and Fragments tables sounded choppy because every frame drew
/// new random choices. Each bin and fragment now crossfades from A to B once: the timbre moves one way.
struct WavetableFactorySmoothnessTests {
    func table(_ p: [ParameterID: ParameterValue]) async throws -> [Float] {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var g = TestProject()
        let a = g.add(.singleCycle, ["shape": .choice("saw")])
        let b = g.add(.singleCycle, ["shape": .choice("square"), "phase": .number(90)])
        let f = g.add(.wavetableFactory, p)
        let k = g.add(.print, ["bitDepth": .choice("32f")])
        g.connect(a, to: f, "in1"); g.connect(b, to: f, "in2"); g.connect(f, to: k)
        let out = dir.appendingPathComponent("o", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = try await RenderEngine.render(RenderRequest(plan: try compile(g.project, assetURLs: [:]), assetURLs: [:], outputDirectory: out))
        return try TestAudio.read(try #require(r.outputs[k])).samples[0]
    }
    func mags(_ x: ArraySlice<Float>) -> [Double] { (1...24).map { h in var re = 0.0, im = 0.0; for (i, v) in x.enumerated() { let w = 2 * Double.pi * Double(h * i) / 2048; re += Double(v) * cos(w); im -= Double(v) * sin(w) }; return sqrt(re*re+im*im) } }
    @Test(arguments: ["linear", "spectral", "fragments"])
    func theTimbreMovesOneWayAcrossTheTable(mode: String) async throws {
        do {
            let snap = "on"
            do {
                let s = try await table(["morphMode": .choice(mode), "snap": .choice(snap)])
                let S = 2048
                let jumps = (1..<64).map { abs(Double(s[$0 * S] - s[$0 * S - 1])) }
                let spectra = (0..<64).map { mags(s[$0 * S..<($0 + 1) * S]) }
                // timbre change per step, and how much it reverses (flicker): sum of |d_k| vs |sum of d_k|
                var stepChange = 0.0, back = 0
                for f in 1..<64 { let d = zip(spectra[f], spectra[f-1]).map { abs($0 - $1) }.reduce(0, +); stepChange = max(stepChange, d)
                    if f > 1 { let up = zip(spectra[f], spectra[f-1]).map { $0 - $1 }; let prev = zip(spectra[f-1], spectra[f-2]).map { $0 - $1 }; if zip(up, prev).map({ $0 * $1 }).reduce(0, +) < 0 { back += 1 } } }
                // Saw to square: no frame-to-frame step reverses the last one, no step is more than about
                // twice the even linear morph's (was 20-50x with fresh random choices per frame), and
                // frames join cleanly with Zero Snap on.
                #expect(back == 0, "\(mode): \(back) reversals")
                #expect(stepChange < 300, "\(mode): largest timbre step \(stepChange)")
                #expect(jumps.sorted()[31] < 0.05, "\(mode): median boundary jump \(jumps.sorted()[31])")
            }
        }
    }
}

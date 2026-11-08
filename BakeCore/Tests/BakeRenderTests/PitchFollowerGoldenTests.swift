import BakeDSP
import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Pins the exact output of the shipped Pitch Follower (pitch and confidence), so the parallel analysis, the whole-file
/// pitch path, zero-phase Glide and the finer resolutions can never change what a saved patch already sounds like (D-019).
///
/// Same recording rule as `ReduxGoldenTests`: set `expected` to `[:]`, run once, paste the literal the failure prints.
/// Hashes come from the Mac that records them (libm differs across platforms).
struct PitchFollowerGoldenTests {
    private typealias Output = bake.dsp.PitchFollowerOutput
    private typealias Unvoiced = bake.dsp.PitchFollowerUnvoiced
    private static let sampleRate = 48_000.0
    private static let frames = 48_000

    private enum Source { case steady, sweep, bass, noise, stereo }

    private struct Case {
        var name: String
        var source: Source = .steady
        var minFreq: Float = 60
        var maxFreq: Float = 1_000
        var glide: Float = 15
        var threshold: Float = 0.6
        var output = Output.log
        var unvoiced = Unvoiced.hold
    }

    private static let cases: [Case] = [
        Case(name: "default"),
        Case(name: "sweep", source: .sweep),
        Case(name: "bass", source: .bass, minFreq: 30, maxFreq: 500),
        Case(name: "noiseHold", source: .noise),
        Case(name: "noiseFall", source: .noise, unvoiced: .fallToMin),
        Case(name: "noiseZero", source: .noise, unvoiced: .zero),
        Case(name: "bassGapsFall", source: .bass, minFreq: 30, maxFreq: 500, unvoiced: .fallToMin),
        Case(name: "linearOutput", source: .sweep, output: .linear),
        Case(name: "noteOutput", source: .sweep, output: .note),
        Case(name: "glideZero", source: .sweep, glide: 0),
        Case(name: "glideLong", source: .sweep, glide: 500),
        Case(name: "strict", source: .bass, minFreq: 30, maxFreq: 500, threshold: 0.9),
        Case(name: "loose", source: .bass, minFreq: 30, maxFreq: 500, threshold: 0.2),
        Case(name: "narrowRange", source: .sweep, minFreq: 150, maxFreq: 300),
        Case(name: "stereo", source: .stereo),
    ]

    private static let expected: [String: String] = [
        "default": "1a9a4695687b7839",
        "sweep": "ad3dea287dc4be19",
        "bass": "3d4bdeb001f3e5eb",
        "noiseHold": "31ff4e0e4e5edfe5",
        "noiseFall": "31ff4e0e4e5edfe5",
        "noiseZero": "31ff4e0e4e5edfe5",
        "bassGapsFall": "8fe0cc2265eef199",
        "linearOutput": "4a99bec116f876a",
        "noteOutput": "ac6858e167923321",
        "glideZero": "83aa87135af6673b",
        "glideLong": "b141e033ff170935",
        "strict": "bb833469e401d5dd",
        "loose": "4136fdf6ebcf03e3",
        "narrowRange": "914ee84aad86719",
        "stereo": "6f1b22f59c83bf6e",
    ]

    private static func channels(_ source: Source) -> [[Float]] {
        func make(_ value: (Double, Int) -> Double) -> [Float] {
            (0..<frames).map { Float(value(Double($0) / sampleRate, $0)) }
        }
        switch source {
        case .steady:
            return [make { t, _ in 0.5 * sin(2 * Double.pi * 220 * t) }]
        case .sweep:
            // 80 → 400 Hz over the second.
            return [make { t, _ in 0.5 * sin(2 * Double.pi * (80 * t + 160 * t * t)) }]
        case .bass:
            // 55 Hz and 110 Hz notes with strong 2nd and 3rd harmonics, with silence between them.
            return [make { t, _ in
                let beat = (t * 3).truncatingRemainder(dividingBy: 1)
                let note = (t * 3).rounded(.down).truncatingRemainder(dividingBy: 2) == 0 ? 55.0 : 110.0
                let gate = beat < 0.75 ? 1.0 : 0.0
                let fundamental = 0.3 * sin(2 * Double.pi * note * t)
                let second = 0.5 * sin(4 * Double.pi * note * t)
                let third = 0.4 * sin(6 * Double.pi * note * t)
                return gate * (fundamental + second + third)
            }]
        case .noise:
            var seed: UInt32 = 21
            return [make { _, _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return 0.4 * (Double(seed >> 8) / Double(1 << 23) - 1)
            }]
        case .stereo:
            return [
                make { t, _ in 0.5 * sin(2 * Double.pi * 180 * t) },
                make { t, _ in 0.3 * sin(2 * Double.pi * 180 * t + 0.4) + 0.1 * sin(2 * Double.pi * 360 * t) },
            ]
        }
    }

    private static func run(_ item: Case) -> (pitch: [Float], confidence: [Float]) {
        let samples = channels(item.source)
        var controls = bake.dsp.PitchFollowerControls()
        controls.minFreq = signal(item.minFreq, 30, 2_000, scale: .exponential)
        controls.maxFreq = signal(item.maxFreq, 100, 4_000, scale: .exponential)
        controls.glide = signal(item.glide, 0, 500)
        controls.threshold = signal(item.threshold, 0, 1)
        controls.output = signal(Float(item.output.rawValue), 0, 2)
        controls.unvoiced = signal(Float(item.unvoiced.rawValue), 0, 2)
        controls.fixedOutput = item.output
        controls.fixedUnvoiced = item.unvoiced
        controls.sampleRate = sampleRate

        let count = Int(bake.dsp.pitchFollowerEstimateCount(frames, sampleRate))
        var estimates = [Float](repeating: 0, count: max(count, 1) * Int(bake.dsp.pitchFollowerFloatsPerEstimate()))
        var scratch = [Double](repeating: 0, count: Int(bake.dsp.pitchFollowerScratchDoubles(sampleRate)))
        var state = bake.dsp.PitchFollowerState()
        var pitch = [Float](repeating: 0, count: frames)
        var confidence = [Float](repeating: 0, count: frames)
        let left = samples[0]
        let right = samples.count > 1 ? samples[1] : []
        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                var input = bake.dsp.AudioInput()
                input.channels.0 = leftPointer.baseAddress
                input.channelCount = 1
                input.frames = frames
                if samples.count > 1 {
                    input.channels.1 = rightPointer.baseAddress
                    input.channelCount = 2
                }
                pitch.withUnsafeMutableBufferPointer { pitchPointer in
                    confidence.withUnsafeMutableBufferPointer { confidencePointer in
                        bake.dsp.renderPitchFollower(
                            &state, controls, input, &estimates, count, &scratch,
                            pitchPointer.baseAddress, confidencePointer.baseAddress, 0, frames
                        )
                    }
                }
            }
        }
        return (pitch, confidence)
    }

    private static func hash(_ channels: [[Float]]) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for channel in channels {
            for sample in channel {
                var bits = sample.bitPattern
                for _ in 0..<4 {
                    value = (value ^ UInt64(bits & 0xff)) &* 0x100000001b3
                    bits >>= 8
                }
            }
        }
        return String(value, radix: 16)
    }

    @Test func shippedPitchFollowerKeepsItsExactOutput() {
        var found: [(String, String)] = []
        for item in Self.cases {
            let result = Self.run(item)
            #expect(result.pitch.allSatisfy { $0.isFinite } && result.confidence.allSatisfy { $0.isFinite }, "\(item.name)")
            found.append((item.name, Self.hash([result.pitch, result.confidence])))
        }
        let wrong = found.filter { Self.expected[$0.0] != $0.1 }.map(\.0)
        let literal = found.map { "        \"\($0.0)\": \"\($0.1)\"," }.joined(separator: "\n")
        #expect(wrong.isEmpty, "Unrecorded or changed: \(wrong). Current hashes, to record:\n[\n\(literal)\n]")
    }
}

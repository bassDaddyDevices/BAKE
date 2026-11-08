import Testing
@testable import BakeGraph

/// Tempo and key from file names.
struct ConformNameTests {
    @Test func aBPMIsANumberNextToBPM() {
        #expect(ConformName.bpm(in: "drums_128bpm") == 128)
        #expect(ConformName.bpm(in: "Bass 92 BPM Am") == 92)
        #expect(ConformName.bpm(in: "loop-BPM140-final") == 140)
        #expect(ConformName.bpm(in: "half 87.5bpm") == 87.5)
        #expect(ConformName.bpm(in: "kick_01") == nil)
        #expect(ConformName.bpm(in: "take 2 bpm") == nil)  // one digit
        #expect(ConformName.bpm(in: "fast 999bpm") == nil)  // out of range
    }

    @Test func aKeyIsALetterWithItsAccidentalAndMode() {
        #expect(ConformName.key(in: "Bass 92 BPM Am") == .init(root: 9, minor: true))
        #expect(ConformName.key(in: "pad_F#min") == .init(root: 6, minor: true))
        #expect(ConformName.key(in: "lead Bb maj") == .init(root: 10, minor: false))
        #expect(ConformName.key(in: "keys_C♯") == .init(root: 1, minor: false))
        #expect(ConformName.key(in: "chord-E") == .init(root: 4, minor: false))
        #expect(ConformName.key(in: "Cb_major") == .init(root: 11, minor: false))
    }

    @Test func ordinaryWordsAreNotKeys() {
        #expect(ConformName.key(in: "kick_01") == nil)
        #expect(ConformName.key(in: "a loop") == nil)
        #expect(ConformName.key(in: "Drums Bounce") == nil)
        #expect(ConformName.key(in: "groove") == nil)
    }
}

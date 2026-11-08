import Testing
@testable import BakeGraph

struct ClockDivisionTests {
    @Test func plainDottedAndTripletLengths() throws {
        #expect(ClockDivision.quarterNotes("1/1") == 4)
        #expect(ClockDivision.quarterNotes("1/4") == 1)
        #expect(ClockDivision.quarterNotes("1/64") == 0.0625)
        #expect(ClockDivision.quarterNotes("1/8d") == 0.75)
        let triplet = try #require(ClockDivision.quarterNotes("1/8t"))
        #expect(abs(triplet - 1.0 / 3.0) < 1e-12)
    }

    @Test func unknownIDsAreRejected() {
        #expect(ClockDivision.quarterNotes("1/3") == nil)
        #expect(ClockDivision.quarterNotes("bar") == nil)
        #expect(ClockDivision.quarterNotes("1/4x") == nil)
    }

    @Test func everyListedIDParses() {
        #expect(ClockDivision.ids.count == 21)
        #expect(ClockDivision.ids.allSatisfy { ClockDivision.quarterNotes($0) != nil })
        #expect(ClockDivision.ids.contains("1/4") && ClockDivision.ids.contains("1/16t"))
    }

    @Test func framesAtATempo() {
        #expect(ClockDivision.frames("1/4", bpm: 120, sampleRate: 48_000) == 24_000)
        #expect(ClockDivision.frames("1/8d", bpm: 120, sampleRate: 48_000) == 18_000)
        #expect(abs(ClockDivision.frames("1/8t", bpm: 120, sampleRate: 48_000) - 8_000) < 1e-9)
        #expect(ClockDivision.frames("1/4", bpm: 60, sampleRate: 44_100) == 44_100)
    }
}

import Testing
@testable import BakeGraph

struct BatchNamesTests {
    @Test func aTypedNameIsNumberedAfterAnUnderscore() {
        #expect(BatchNames.numbered("Kick", pass: 0, digits: 3) == "Kick_001")
        #expect(BatchNames.numbered("Kick", pass: 11, digits: 1) == "Kick_12")
        #expect(BatchNames.numbered("Big Snare", pass: 4, digits: 2) == "Big Snare_05")
        #expect(BatchNames.numbered("  ", pass: 0, digits: 3) == "bake_001")
        #expect(BatchNames.numbered("Kick", pass: 1_233, digits: 3) == "Kick_1234")
    }

    @Test func theBuiltInListsAreWholeAndClean() {
        let lists = WordLists.builtIn
        #expect(lists.adjectives.count == 300 && lists.prefixes.count == 154 && lists.suffixes.count == 60)
        for list in [lists.adjectives, lists.prefixes, lists.suffixes] {
            #expect(Set(list).count == list.count)
            #expect(list.allSatisfy { word in !word.isEmpty && word.allSatisfy { $0.isLetter || $0 == "_" } })
        }
        #expect(lists.suffixes.allSatisfy { $0.hasPrefix("of_") })
    }

    @Test func randomNamesAreAdjectivePrefixSuffix() {
        let lists = WordLists.builtIn
        for name in BatchNames.random(seed: 1, passes: 50) {
            let parts = name.split(separator: "_", maxSplits: 2).map(String.init)
            #expect(parts.count == 3, "\(name)")
            #expect(lists.adjectives.contains(parts[0]) && lists.prefixes.contains(parts[1]) && lists.suffixes.contains(parts[2]), "\(name)")
        }
    }

    @Test func theSameSeedGivesTheSameNamesAndNoneRepeat() {
        let one = BatchNames.random(seed: 7, passes: 2_000)
        #expect(one == BatchNames.random(seed: 7, passes: 2_000))
        #expect(one != BatchNames.random(seed: 8, passes: 2_000))
        #expect(Set(one).count == 2_000)
        // A longer batch keeps the first names.
        #expect(Array(BatchNames.random(seed: 7, passes: 3_000).prefix(2_000)) == one)
    }

    @Test func tinyListsStillGiveEveryPassItsOwnName() throws {
        let lists = try #require(WordLists(adjectives: "Red\n", prefixes: " Fox \n\n", suffixes: "of Doom"))
        #expect(lists.suffixes == ["of_Doom"])
        #expect(BatchNames.random(seed: 1, passes: 3, lists: lists) == ["Red_Fox_of_Doom", "Red_Fox_of_Doom_2", "Red_Fox_of_Doom_3"])
        #expect(WordLists(adjectives: "", prefixes: "Fox", suffixes: "of_Doom") == nil)
    }
}

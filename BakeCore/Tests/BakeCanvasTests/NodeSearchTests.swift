import Testing
import BakeGraph
@testable import BakeCanvas

struct NodeSearchTests {
    private let menu = NodeCategory.allCases.filter(\.isInAddMenu).flatMap(\.kinds)

    private func search(_ query: String) -> [NodeKind] {
        NodeSearch.kinds(matching: query, among: menu)
    }

    @Test func anEmptyQueryListsEveryNodeInMenuOrder() {
        #expect(search("") == menu)
        #expect(search("  ") == menu)
    }

    @Test func titlesThatStartWithTheQueryComeFirst() {
        #expect(search("rev").prefix(2) == [.reverb, .reverse])
        // "OTFT Compressor" has a word starting "comp", so it follows Compressor.
        #expect(search("comp").prefix(2) == [.compressor, .otftCompressor])
    }

    @Test func otherNamesAndTheMenuPathFindNodes() {
        #expect(search("echo") == [.delay])
        #expect(search("dynamics") == [.compressor, .limiter, .otftCompressor])
        #expect(search("bitcrush") == [.redux])
    }

    @Test func everyWordMustMatchAndPunctuationAndCaseDontMatter() {
        #expect(search("gain vca").first == .gainVCA)
        #expect(search("mid side") == [.midSideEncoder, .midSideDecoder])
        #expect(search("RÉVERB").first == .reverb)
        #expect(search("xyzzy").isEmpty)
        #expect(search("reverb xyzzy").isEmpty)
    }

    @Test func eachNodeShowsWhereItIsInTheMenu() {
        #expect(NodeKind.compressor.menuPath == "Effects › Dynamics")
        #expect(NodeKind.vocoder.menuPath == "Effects › Spectral")
        #expect(NodeKind.delay.menuPath == "Time")
    }

    @Test func customNodesMatchByName() {
        #expect(NodeSearch.matches("dub", name: "Dub Echo Chain"))
        #expect(NodeSearch.matches("echo ch", name: "Dub Echo Chain"))
        #expect(!NodeSearch.matches("verb", name: "Dub Echo Chain"))
    }
}

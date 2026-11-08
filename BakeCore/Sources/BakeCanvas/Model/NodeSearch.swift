import BakeGraph
import Foundation

/// Finding a node by typing: what the Add Node search lists for a query.
public enum NodeSearch {
    /// The kinds that match `query`, best first; an empty query lists them all in menu order.
    /// Every word typed must start a word of the node's title, its other names or its menu path.
    /// Best are titles that start with the query, then titles with a word that does, then the rest;
    /// ties keep menu order.
    public static func kinds(matching query: String, among kinds: [NodeKind]) -> [NodeKind] {
        let typed = words(query)
        guard !typed.isEmpty else { return kinds }
        let joined = typed.joined(separator: " ")
        let ranked = kinds.enumerated().compactMap { index, kind -> (rank: Int, index: Int, kind: NodeKind)? in
            let title = words(kind.title)
            let everything = title + words(kind.searchKeywords) + words(kind.menuPath)
            guard typed.allSatisfy({ word in everything.contains { $0.hasPrefix(word) } }) else { return nil }
            let rank = title.joined(separator: " ").hasPrefix(joined) ? 0
                : title.contains(where: { $0.hasPrefix(typed[0]) }) ? 1
                : 2
            return (rank, index, kind)
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.kind)
    }

    /// Whether a custom node's name matches, by the same word rule.
    public static func matches(_ query: String, name: String) -> Bool {
        let typed = words(query)
        let named = words(name)
        return typed.allSatisfy { word in named.contains { $0.hasPrefix(word) } }
    }

    /// Lowercased words, accents dropped, split at anything that isn't a letter or digit, so
    /// "Gain / VCA" is "gain vca" and "Mid/Side" is "mid side".
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

extension NodeKind {
    /// Where the kind sits in Add Node, for the search list: "Effects › Dynamics", "Time".
    public var menuPath: String {
        if let subgroup { return "\(category.title) › \(subgroup.title)" }
        if let parent = category.parent { return "\(parent.title) › \(category.title)" }
        return category.title
    }

    /// Other names people type for this node.
    var searchKeywords: String {
        switch self {
        case .audio: "file sample import"
        case .batchAudio: "folder many files"
        case .batchBake: "export folder many files"
        case .largeAudio: "slice slicer chop long recording split"
        case .concatenate: "join stitch combine sequence"
        case .corpusScatter: "scatter texture grains cloud timeline euclidean"
        case .forEachSplitter: "split branch route round robin odd even distribute"
        case .batchConform: "conform tempo key bpm match stretch repitch normalize warp"
        case .photoBooth: "snapshot capture chop chunk grab trigger grid every quarter slice"
        case .merryGoRound: "merry go round carousel deal rotate distribute chunks ping pong pattern"
        case .spectralSorter: "sort classify route centroid brightness loudness pitch decay kick snare hat"
        case .combinatorialMatrix: "layer layering stack combine every combination permutation"
        case .ensembleAverager: "average composite blend spectral"
        case .generator: "noise oscillator tone"
        case .preview: "play listen"
        case .print: "export render output"
        case .filters: "eq lowpass highpass bandpass notch lpf hpf cutoff resonance"
        case .dualFilter: "eq lowpass highpass"
        case .resonator: "comb modal ring"
        case .distortion: "drive overdrive saturation fuzz clip"
        case .redux: "bitcrush crusher lofi downsample"
        case .waveshaper: "saturation drive"
        case .wavefolder: "fold"
        case .subHarmonic: "octave sub bass"
        case .tapeDegrade: "tape wow flutter lofi"
        case .adaptiveClipping: "clipper clip"
        case .compressor: "comp sidechain ducking gate expander"
        case .limiter: "loudness ceiling maximizer"
        case .chorus: "unison detune"
        case .frequencyShifter: "bode shift"
        case .delay: "echo"
        case .convolver: "ir impulse convolution"
        case .reverb: "verb space room hall"
        case .granularCloud: "grains granular"
        case .stretch: "timestretch pitch"
        case .reverse: "backwards"
        case .halfTime: "slow"
        case .stutter: "glitch repeat"
        case .looper: "loop"
        case .vocoder: "talkbox"
        case .spectralResynthesis: "additive partials"
        case .otftCompressor: "multiband dynamics"
        case .mixer: "sum combine"
        case .gainVCA: "volume amp level"
        case .utility: "normalize trim pad fade dc polarity mono gain"
        case .stepSwitch: "select"
        case .feedback: "loop"
        case .lfo: "oscillator"
        case .random: "chance"
        case .sampleAndHold: "s&h"
        case .envelope: "adsr"
        case .transientDetector: "onset"
        case .featureFollower: "centroid analysis"
        case .clock: "tempo bpm trigger"
        default: ""
        }
    }
}

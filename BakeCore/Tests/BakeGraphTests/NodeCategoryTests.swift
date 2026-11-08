import Testing
@testable import BakeGraph

struct NodeCategoryTests {
    /// A new node kind must be put in a group, or it won't appear in the Add Node menu.
    @Test func everyKindIsInExactlyOneCategory() {
        let listed = NodeCategory.allCases.flatMap(\.kinds)
        #expect(listed.count == Set(listed).count, "a kind is listed twice")
        let offered = Set(NodeKind.allCases.filter { !$0.isLegacy })
        #expect(Set(listed) == offered, "missing: \(offered.subtracting(listed))")
    }

    @Test func groupsHoldWhatTheirNamesSay() {
        #expect(NodeCategory.inOut.kinds == [.audio, .generator, .preview, .print])
        #expect(NodeCategory.batch.kinds == [.batchAudio, .largeAudio, .photoBooth, .concatenate, .corpusScatter, .ensembleAverager, .combinatorialMatrix, .forEachSplitter, .spectralSorter, .merryGoRound, .batchConform, .batchBake])
        #expect(NodeCategory.spectral.kinds == [.vocoder, .spectralResynthesis, .fractalFilter, .otftCompressor])
        #expect(NodeCategory.modulation.kinds == [.lfo, .random, .sampleAndHold, .macro, .envelope, .envelopeFollower, .pitchFollower, .transientDetector, .featureFollower, .clock, .math, .logic, .quantizer])
        #expect(NodeCategory.wavetable.kinds == [.singleCycle, .wavetableFactory])
        #expect(NodeCategory.effects.kinds.first == .filters)
        #expect(NodeCategory.effects.kinds == [.filters, .dualFilter, .resonator, .distortion, .redux, .waveshaper, .wavefolder, .derivativeDistortion, .residualExplosion, .subHarmonic, .tapeDegrade, .adaptiveClipping, .compressor, .limiter, .phaser, .flanger, .chorus, .frequencyShifter])
        #expect(NodeCategory.time.kinds == [.delay, .convolver, .reverb, .granularCloud, .temporalShatter, .halfTime, .beatRepeat, .looper, .stutter, .stepFX, .stretch, .reverse])
        #expect(NodeCategory.routing.kinds.contains(.midSideDecoder))
        #expect(NodeCategory.routing.kinds.contains(.utility))
        #expect(NodeCategory.allCases.allSatisfy { !$0.kinds.isEmpty })
    }

    /// Effects is split into submenus, and Spectral is listed inside it; every effect is in one submenu.
    @Test func effectsHasSubmenusAndHoldsSpectral() {
        #expect(NodeCategory.effects.subgroups == [.filters, .distortion, .dynamics, .modulationFX])
        #expect(NodeCategory.allCases.filter { $0 != .effects }.allSatisfy { $0.subgroups.isEmpty })
        #expect(NodeCategory.effects.kinds.allSatisfy { $0.subgroup != nil })
        #expect(NodeKind.compressor.subgroup == .dynamics)
        #expect(NodeKind.chorus.subgroup == .modulationFX)
        #expect(NodeKind.reverb.subgroup == nil)
        #expect(NodeCategory.spectral.parent == .effects)
        #expect(NodeCategory.effects.children == [.spectral])
        #expect(NodeCategory.allCases.filter { $0.parent != nil } == [.spectral])
    }

    @Test func eachKindKnowsItsCategory() {
        #expect(NodeKind.clock.category == .modulation)
        #expect(NodeKind.singleCycle.category == .wavetable)
        #expect(NodeKind.singleCycle.category == .wavetable)
        #expect(NodeKind.resonator.category == .effects)
        #expect(NodeKind.mixer.category == .routing)
    }
}

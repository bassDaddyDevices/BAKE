import Testing
@testable import BakeGraph

struct BatchFileNameTests {
    @Test func tokensBecomeTheSourceNameAndThePassNumber() {
        #expect(BatchFileName.resolve("{source}", source: "kick", pass: 0, count: 3) == "kick")
        #expect(BatchFileName.resolve("{source}_verb", source: "kick", pass: 0, count: 3) == "kick_verb")
        #expect(BatchFileName.resolve("hit {n}", source: "kick", pass: 6, count: 120) == "hit 007")
        #expect(BatchFileName.resolve("{n}", source: "kick", pass: 0, count: 9) == "1")
    }

    @Test func anEmptyResultFallsBackToTheSourceName() {
        #expect(BatchFileName.resolve("  ", source: "kick", pass: 0, count: 1) == "kick")
    }

    @Test func aNameWithoutTokensIsTheSameEveryPass() {
        #expect(BatchFileName.varies("{source}") && BatchFileName.varies("take {n}"))
        #expect(!BatchFileName.varies("bounce"))
    }
}

struct BatchRunTests {
    private struct Patch {
        var project = ProjectFile()
        let drums: NodeID, rooms: NodeID, mixer: NodeID, lfo: NodeID, bake: NodeID
    }

    /// Two Batch Audio nodes (drums, rooms) → Mixer → Batch Bake, an LFO on the drums' gain.
    private func patch() throws -> Patch {
        var project = ProjectFile()
        let drums = project.addNode(.batchAudio, at: CanvasPoint())
        let rooms = project.addNode(.batchAudio, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        let bake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: "/drums"), for: drums)
        project.setSourceFolder(FileReference(lastKnownPath: "/rooms"), for: rooms)
        project.setModulated("gain", of: drums, true)
        try project.connect(from: PinRef(node: drums, pin: "out"), to: PinRef(node: mixer, pin: "in1"))
        try project.connect(from: PinRef(node: rooms, pin: "out"), to: PinRef(node: mixer, pin: "in2"))
        try project.connect(from: PinRef(node: lfo, pin: "out"), to: PinRef(node: drums, pin: "mod.gain"))
        try project.connect(from: PinRef(node: mixer, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.setParameter("gain", of: drums, to: .number(6))
        return Patch(project: project, drums: drums, rooms: rooms, mixer: mixer, lfo: lfo, bake: bake)
    }

    private let drums = ["/drums/kick.wav", "/drums/snare.wav", "/drums/hat.wav"].map { BatchFile(path: $0) }
    private let rooms = ["/rooms/hall.wav", "/rooms/plate.aif"].map { BatchFile(path: $0) }

    private func path(of node: NodeID, in pass: ProjectFile) -> String? {
        pass.assets.first { $0.id == pass.node(node)?.assetID }?.lastKnownPath
    }

    @Test func eachPassPlaysTheNextFileAsAnAudioNode() throws {
        let patch = try patch()
        let run = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms])
        #expect(run.passCount == 3)
        let second = run.pass(1)
        #expect(second.node(patch.drums)?.kind == .audio)
        #expect(second.node(patch.drums)?.sourceFolder == nil)
        #expect(path(of: patch.drums, in: second) == "/drums/snare.wav")
        #expect(second.node(patch.bake)?.kind == .print)
        #expect(second.node(patch.bake)?.parameters["prefix"] == .text("snare"))
        #expect(second.edges == patch.project.edges)
        #expect(second.nodes.map(\.id) == patch.project.nodes.map(\.id))
    }

    @Test func aSmallerFolderStartsOver() throws {
        let patch = try patch()
        let run = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms])
        #expect(path(of: patch.rooms, in: run.pass(0)) == "/rooms/hall.wav")
        #expect(path(of: patch.rooms, in: run.pass(1)) == "/rooms/plate.aif")
        #expect(path(of: patch.rooms, in: run.pass(2)) == "/rooms/hall.wav")
    }

    @Test func passesAreTheSameEveryTime() throws {
        let patch = try patch()
        let files = [patch.drums: drums, patch.rooms: rooms]
        #expect(BatchRun(project: patch.project, files: files).pass(1) == BatchRun(project: patch.project, files: files).pass(1))
        #expect(BatchRun.assetID(of: patch.drums, pass: 0) == BatchRun.assetID(of: patch.drums, pass: 0))
        #expect(BatchRun.assetID(of: patch.drums, pass: 0) != BatchRun.assetID(of: patch.drums, pass: 1))
        #expect(BatchRun.assetID(of: patch.drums, pass: 0) != BatchRun.assetID(of: patch.rooms, pass: 0))
    }

    /// The swap keeps the Batch Audio's gain and its modulation wire, and the pass compiles.
    @Test func gainAndModulationComeAlongAndThePassCompiles() throws {
        let patch = try patch()
        let run = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms])
        let pass = run.pass(0)
        #expect(pass.node(patch.drums)?.parameters["gain"] == .number(6))
        #expect(pass.node(patch.drums)?.modulated == ["gain"])
        let info = AssetInfo(frameCount: 4_800, channelCount: 1, sampleRate: 48_000)
        let assets = [
            BatchRun.assetID(of: patch.drums, pass: 0): info,
            BatchRun.assetID(of: patch.rooms, pass: 0): AssetInfo(frameCount: 9_600, channelCount: 2, sampleRate: 48_000),
        ]
        let plan = try GraphCompiler.compile(pass, assets: assets)
        #expect(plan.steps.contains { $0.node == patch.drums && $0.kind == .audio })
        #expect(plan.steps.first { $0.node == patch.bake }?.shape == SignalShape(frames: 9_600, channels: 2))
    }

    @Test func namesUseTheFirstBatchAudioFeedingTheBakeAndThePassNumber() throws {
        var patch = try patch()
        patch.project.setParameter("name", of: patch.bake, to: .text("{source} {n}"))
        let run = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms])
        #expect(run.fileName(of: patch.bake, pass: 2) == "hat 3")
    }

    @Test func skipBecomesOverwriteInThePass() throws {
        var patch = try patch()
        patch.project.setParameter("versions", of: patch.bake, to: .choice("skip"))
        let run = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms])
        #expect(run.pass(0).node(patch.bake)?.parameters["versions"] == .choice("overwrite"))
    }

    @Test func aReadyPatchHasNoIssues() throws {
        let patch = try patch()
        #expect(BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms]).issues().isEmpty)
    }

    @Test func problemsAreFoundBeforeRenderingOnTheRightCard() throws {
        var patch = try patch()
        // The rooms folder is empty; the drums lose their folder.
        patch.project.setSourceFolder(nil, for: patch.drums)
        var issues = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: []]).issues()
        #expect(issues == [.noFolder(patch.drums), .emptyFolder(patch.rooms)])

        // A plain Bake fed by a Batch Audio, a Batch Bake fed by nothing batched, and Overwrite with a fixed name.
        patch = try self.patch()
        let plain = patch.project.addNode(.print, at: CanvasPoint())
        try patch.project.connect(from: PinRef(node: patch.mixer, pin: "out"), to: PinRef(node: plain, pin: "in"))
        let noise = patch.project.addNode(.generator, at: CanvasPoint())
        let lonely = patch.project.addNode(.batchBake, at: CanvasPoint())
        try patch.project.connect(from: PinRef(node: noise, pin: "out"), to: PinRef(node: lonely, pin: "in"))
        patch.project.setParameter("versions", of: patch.bake, to: .choice("overwrite"))
        patch.project.setParameter("name", of: patch.bake, to: .text("bounce"))
        issues = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms]).issues()
        #expect(Set(issues) == [.plainBakeInBatch(plain), .noBatchSource(lonely), .sameNameEveryPass(patch.bake)])
        #expect(issues.allSatisfy { !$0.message.isEmpty })
    }

    @Test func aBatchAudioFeedingNothingIsLeftAlone() throws {
        var project = ProjectFile()
        let idle = project.addNode(.batchAudio, at: CanvasPoint())
        let audio = project.addNode(.audio, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: bake, pin: "in"))
        let run = BatchRun(project: project, files: [:])
        #expect(run.issues().isEmpty)
        #expect(!run.hasBatch)
        #expect(run.singlePass()?.node(idle)?.kind == .batchAudio)
        #expect(run.batchPass(0) == nil)
    }

    /// Bake All: the plain Bakes and Previews once, the Batch Bakes on their own in every pass.
    @Test func plainOutputsRenderOnceAndBatchBakesEveryPass() throws {
        var patch = try patch()
        let preview = patch.project.addNode(.preview, at: CanvasPoint())
        try patch.project.connect(from: PinRef(node: patch.mixer, pin: "out"), to: PinRef(node: preview, pin: "in"))
        let run = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms])
        #expect(run.hasBatch)
        let single = try #require(run.singlePass())
        #expect(single.node(preview) != nil && single.node(patch.bake) == nil)
        #expect(path(of: patch.drums, in: single) == "/drums/kick.wav")
        let second = try #require(run.batchPass(1))
        #expect(second.node(preview) == nil && second.node(patch.bake)?.kind == .print)
        #expect(run.batchPass(1, skipping: [patch.bake]) == nil)
    }

    /// Before a bake, cards show lengths from the first files.
    @Test func cardLengthsComeFromTheFirstFiles() throws {
        let patch = try patch()
        let run = BatchRun(project: patch.project, files: [patch.drums: drums, patch.rooms: rooms])
        let assets = [
            BatchRun.assetID(of: patch.drums, pass: 0): AssetInfo(frameCount: 4_800, channelCount: 1, sampleRate: 48_000),
            BatchRun.assetID(of: patch.rooms, pass: 0): AssetInfo(frameCount: 9_600, channelCount: 2, sampleRate: 48_000),
        ]
        let shapes = GraphCompiler.previewShapes(run.pass(0), assets: assets)
        #expect(shapes[patch.drums]?.frames == 4_800)
        #expect(shapes[patch.bake]?.frames == 9_600)
    }

    /// Batch Audio → Filters → Concatenate → Reverb → Bake, and Filters → Batch Bake on a branch.
    private func gatherPatch() throws -> (ProjectFile, source: NodeID, filters: NodeID, gather: NodeID, reverb: NodeID, bake: NodeID, batchBake: NodeID) {
        var project = ProjectFile()
        let source = project.addNode(.batchAudio, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let gather = project.addNode(.concatenate, at: CanvasPoint())
        let reverb = project.addNode(.reverb, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint())
        let batchBake = project.addNode(.batchBake, at: CanvasPoint())
        project.setSourceFolder(FileReference(lastKnownPath: "/drums"), for: source)
        try project.connect(from: PinRef(node: source, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: gather, pin: "in1"))
        try project.connect(from: PinRef(node: gather, pin: "out"), to: PinRef(node: reverb, pin: "in"))
        try project.connect(from: PinRef(node: reverb, pin: "out"), to: PinRef(node: bake, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: batchBake, pin: "in"))
        return (project, source, filters, gather, reverb, bake, batchBake)
    }

    @Test func aPassCapturesWhatReachesTheGather() throws {
        let (project, source, _, gather, reverb, bake, batchBake) = try gatherPatch()
        let run = BatchRun(project: project, files: [source: drums])
        #expect(run.issues().isEmpty)
        #expect(run.gathers == [gather])
        let pass = try #require(run.batchPass(1))
        // Concatenate joins its inputs in the pass, and a hidden 32-bit float Bake captures what it makes.
        let capture = BatchRun.captureNode(of: gather)
        #expect(pass.node(gather)?.kind == .concatenate)
        #expect(pass.node(capture)?.kind == .print)
        #expect(pass.node(capture)?.parameters["prefix"] == .text(BatchRun.captureName(of: gather, pass: 1)))
        #expect(pass.node(capture)?.parameters["bitDepth"] == .choice("32f"))
        #expect(pass.edges.filter { $0.from.node == gather }.map(\.to.node) == [capture])
        #expect(pass.node(bake) == nil && pass.node(batchBake)?.kind == .print)
        // The Bake after the gather renders once, after the passes; nothing renders it before them.
        #expect(run.singlePass() == nil)
        _ = reverb
    }

    @Test func theAfterPassPlaysTheJoinedFileIntoWhatFollows() throws {
        let (project, source, filters, gather, reverb, bake, batchBake) = try gatherPatch()
        let run = BatchRun(project: project, files: [source: drums])
        let joined = AssetReference(lastKnownPath: "/tmp/joined.wav")
        let after = try #require(run.afterPass(joined: [gather: joined]))
        #expect(after.node(gather)?.kind == .audio)
        #expect(after.node(gather)?.assetID == joined.id)
        #expect(after.assets.contains(joined))
        #expect(!after.edges.contains { $0.to.node == gather })
        #expect(after.edges.contains { $0.from.node == gather && $0.to.node == reverb })
        #expect(after.node(bake) != nil && after.node(batchBake) == nil)
        let plan = try GraphCompiler.compile(after, assets: [joined.id: AssetInfo(frameCount: 9_600, channelCount: 2, sampleRate: 48_000)])
        #expect(plan.steps.contains { $0.node == bake })
        #expect(!plan.steps.contains { $0.node == filters })
    }

    @Test func gatherProblemsAreFoundBeforeRendering() throws {
        var project = ProjectFile()
        let noise = project.addNode(.generator, at: CanvasPoint())
        let gather = project.addNode(.concatenate, at: CanvasPoint())
        let after = project.addNode(.batchBake, at: CanvasPoint())
        try project.connect(from: PinRef(node: noise, pin: "out"), to: PinRef(node: gather, pin: "in1"))
        try project.connect(from: PinRef(node: gather, pin: "out"), to: PinRef(node: after, pin: "in"))
        let issues = BatchRun(project: project, files: [:]).issues()
        // Without a batch before it a Concatenate just joins its inputs, so the problem is the Batch Bake: no batch to write.
        #expect(Set(issues) == [.noBatchSource(after)])
        // A plain Bake after a Concatenate is one file, not a Bake in a batch.
        let (patch, source, _, _, _, _, _) = try gatherPatch()
        #expect(BatchRun(project: patch, files: [source: drums]).issues().isEmpty)
    }

    @Test func batchBakesNameFilesByTheirNaming() throws {
        var patch = try patch()
        let files = [patch.drums: drums, patch.rooms: rooms]
        patch.project.setParameter("naming", of: patch.bake, to: .choice("numbered"))
        patch.project.setParameter("name", of: patch.bake, to: .text("Kick"))
        var run = BatchRun(project: patch.project, files: files)
        #expect((0..<3).map { run.fileName(of: patch.bake, pass: $0) } == ["Kick_001", "Kick_002", "Kick_003"])
        // A fixed typed name with Overwrite is fine: the number keeps files apart.
        patch.project.setParameter("versions", of: patch.bake, to: .choice("overwrite"))
        #expect(BatchRun(project: patch.project, files: files).issues().isEmpty)

        patch.project.setParameter("naming", of: patch.bake, to: .choice("random"))
        patch.project.setParameter("seed", of: patch.bake, to: .number(9))
        run = BatchRun(project: patch.project, files: files)
        #expect((0..<3).map { run.fileName(of: patch.bake, pass: $0) } == BatchNames.random(seed: 9, passes: 3))
        #expect(run.pass(1).node(patch.bake)?.parameters["prefix"] == .text(BatchNames.random(seed: 9, passes: 3)[1]))
        let lists = try #require(WordLists(adjectives: "Red", prefixes: "Fox", suffixes: "of_Doom"))
        run = BatchRun(project: patch.project, files: files, wordLists: lists)
        #expect(run.fileName(of: patch.bake, pass: 0) == "Red_Fox_of_Doom")
    }
}

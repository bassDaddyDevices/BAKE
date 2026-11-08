import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Custom Nodes Phase A (spec §12): definitions in the document, flattened before compiling, so a
/// custom node renders exactly what its nodes would render placed directly.
struct CustomNodeTests {
    private static func id(_ number: Int) -> NodeID { NodeID(testUUID(50_000 + number)) }

    /// Custom Input → Filters → Distortion → Custom Output.
    private static let chain = CustomNodeDefinition(
        id: testUUID(60_001), name: "Crunch",
        nodes: [
            Node(id: id(1), kind: .customInput),
            Node(id: id(2), kind: .filters, parameters: ["cutoff": .number(800)]),
            Node(id: id(3), kind: .distortion, parameters: ["drive": .number(9)]),
            Node(id: id(4), kind: .customOutput),
        ],
        edges: [
            Edge(from: PinRef(node: id(1), pin: "out"), to: PinRef(node: id(2), pin: "in")),
            Edge(from: PinRef(node: id(2), pin: "out"), to: PinRef(node: id(3), pin: "in")),
            Edge(from: PinRef(node: id(3), pin: "out"), to: PinRef(node: id(4), pin: "in")),
        ]
    )

    /// Custom Input → Filters (cutoff at its minimum) ← Macro on Cutoff; → Custom Output.
    private static let sweep = CustomNodeDefinition(
        id: testUUID(60_002), name: "Sweep",
        nodes: [
            Node(id: id(11), kind: .customInput),
            Node(id: id(12), kind: .filters, parameters: ["cutoff": .number(20)], modulated: ["cutoff"]),
            Node(id: id(13), kind: .macro, parameters: ["value": .number(0.25)]),
            Node(id: id(14), kind: .customOutput),
        ],
        edges: [
            Edge(from: PinRef(node: id(11), pin: "out"), to: PinRef(node: id(12), pin: "in")),
            Edge(from: PinRef(node: id(13), pin: "out1"), to: PinRef(node: id(12), pin: "mod.cutoff")),
            Edge(from: PinRef(node: id(12), pin: "out"), to: PinRef(node: id(14), pin: "in")),
        ]
    )

    private func custom(_ graph: inout TestProject, _ definition: CustomNodeDefinition, parameters: [ParameterID: ParameterValue] = [:],
                        modulated: [ParameterID] = []) -> NodeID {
        if !graph.project.customNodes.contains(where: { $0.id == definition.id }) { graph.project.customNodes.append(definition) }
        let node = graph.add(.custom, parameters, modulated: modulated)
        graph.project.nodes[graph.project.nodes.count - 1].customDefinition = definition.id
        return node
    }

    private func bake(_ graph: TestProject, _ bake: NodeID) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 12_000, channels: 2), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(graph.project, assetURLs: urls), assetURLs: urls, outputDirectory: output, chunkFrames: 777)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples
    }

    @Test func aCustomNodeBakesExactlyLikeItsNodesPlacedDirectly() async throws {
        var wrapped = TestProject()
        let audio = wrapped.add(.audio, asset: sourceAsset)
        let crunch = custom(&wrapped, Self.chain)
        let bakeA = wrapped.add(.print, ["bitDepth": .choice("32f")])
        wrapped.connect(audio, to: crunch, "in1")
        wrapped.project.edges.append(Edge(from: PinRef(node: crunch, pin: "out1"), to: PinRef(node: bakeA, pin: "in")))

        var direct = TestProject()
        let source = direct.add(.audio, asset: sourceAsset)
        let filters = direct.add(.filters, ["cutoff": .number(800)])
        let distortion = direct.add(.distortion, ["drive": .number(9)])
        let bakeB = direct.add(.print, ["bitDepth": .choice("32f")])
        direct.connect(source, to: filters)
        direct.connect(filters, to: distortion)
        direct.connect(distortion, to: bakeB)

        #expect(try await bake(wrapped, bakeA) == bake(direct, bakeB))
    }

    @Test func twoInstancesDontCollideAndCompileTheSameEveryTime() throws {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let first = custom(&graph, Self.chain)
        let second = custom(&graph, Self.chain)
        let bake = graph.add(.print)
        graph.connect(audio, to: first, "in1")
        graph.project.edges.append(Edge(from: PinRef(node: first, pin: "out1"), to: PinRef(node: second, pin: "in1")))
        graph.project.edges.append(Edge(from: PinRef(node: second, pin: "out1"), to: PinRef(node: bake, pin: "in")))
        let assets = [sourceAsset: AssetInfo(frameCount: 12_000, channelCount: 2, sampleRate: 48_000)]
        let plan = try GraphCompiler.compile(graph.project, assets: assets)
        // Audio, two Filters, two Distortions, Bake.
        #expect(plan.steps.count == 6)
        #expect(Set(plan.steps.map(\.node)).count == 6)
        #expect(try GraphCompiler.compile(graph.project, assets: assets) == plan)
    }

    @Test func theMacroControlSetsTheMacroInside() async throws {
        // macro.1 = 1 on the custom node equals the same patch built directly with the Macro at 1.
        var wrapped = TestProject()
        let audio = wrapped.add(.audio, asset: sourceAsset)
        let sweep = custom(&wrapped, Self.sweep, parameters: ["macro.1": .number(1)])
        let bakeA = wrapped.add(.print, ["bitDepth": .choice("32f")])
        wrapped.connect(audio, to: sweep, "in1")
        wrapped.project.edges.append(Edge(from: PinRef(node: sweep, pin: "out1"), to: PinRef(node: bakeA, pin: "in")))

        var direct = TestProject()
        let source = direct.add(.audio, asset: sourceAsset)
        let filters = direct.add(.filters, ["cutoff": .number(20)], modulated: ["cutoff"])
        let macro = direct.add(.macro, ["value": .number(1)])
        let bakeB = direct.add(.print, ["bitDepth": .choice("32f")])
        direct.connect(source, to: filters)
        direct.project.edges.append(Edge(from: PinRef(node: macro, pin: "out1"), to: PinRef(node: filters, pin: "mod.cutoff")))
        direct.connect(filters, to: bakeB)

        let viaCustom = try await bake(wrapped, bakeA)
        #expect(viaCustom == (try await bake(direct, bakeB)))
        // And the control does something: the definition's own 0.25 sounds different.
        var unset = TestProject()
        let audio2 = unset.add(.audio, asset: sourceAsset)
        let sweep2 = custom(&unset, Self.sweep)
        let bakeC = unset.add(.print, ["bitDepth": .choice("32f")])
        unset.connect(audio2, to: sweep2, "in1")
        unset.project.edges.append(Edge(from: PinRef(node: sweep2, pin: "out1"), to: PinRef(node: bakeC, pin: "in")))
        #expect(try await bake(unset, bakeC) != viaCustom)
    }

    @Test func modulatingTheMacroControlModulatesTheMacroInside() async throws {
        var wrapped = TestProject()
        let audio = wrapped.add(.audio, asset: sourceAsset)
        let lfo = wrapped.add(.lfo, ["rate": .number(3)])
        let sweep = custom(&wrapped, Self.sweep, parameters: ["macro.1": .number(0.5)], modulated: ["macro.1"])
        wrapped.project.nodes[2].setTrim(0.5, for: "macro.1")
        let bakeA = wrapped.add(.print, ["bitDepth": .choice("32f")])
        wrapped.connect(audio, to: sweep, "in1")
        wrapped.connect(lfo, to: sweep, "mod.macro.1")
        wrapped.project.edges.append(Edge(from: PinRef(node: sweep, pin: "out1"), to: PinRef(node: bakeA, pin: "in")))

        var direct = TestProject()
        let source = direct.add(.audio, asset: sourceAsset)
        let lfo2 = direct.add(.lfo, ["rate": .number(3)])
        let filters = direct.add(.filters, ["cutoff": .number(20)], modulated: ["cutoff"])
        let macro = direct.add(.macro, ["value": .number(0.5)], modulated: ["value"])
        direct.project.nodes[3].setTrim(0.5, for: "value")
        let bakeB = direct.add(.print, ["bitDepth": .choice("32f")])
        direct.connect(source, to: filters)
        direct.connect(lfo2, to: macro, "mod.value")
        direct.project.edges.append(Edge(from: PinRef(node: macro, pin: "out1"), to: PinRef(node: filters, pin: "mod.cutoff")))
        direct.connect(filters, to: bakeB)

        #expect(try await bake(wrapped, bakeA) == bake(direct, bakeB))
    }

    @Test func anInputWiredStraightToAnOutputPassesThrough() async throws {
        let passthrough = CustomNodeDefinition(
            id: testUUID(60_003), name: "Thru",
            nodes: [Node(id: Self.id(21), kind: .customInput), Node(id: Self.id(22), kind: .customOutput)],
            edges: [Edge(from: PinRef(node: Self.id(21), pin: "out"), to: PinRef(node: Self.id(22), pin: "in"))]
        )
        var wrapped = TestProject()
        let audio = wrapped.add(.audio, asset: sourceAsset)
        let thru = custom(&wrapped, passthrough)
        let bakeA = wrapped.add(.print, ["bitDepth": .choice("32f")])
        wrapped.connect(audio, to: thru, "in1")
        wrapped.project.edges.append(Edge(from: PinRef(node: thru, pin: "out1"), to: PinRef(node: bakeA, pin: "in")))
        var direct = TestProject()
        let source = direct.add(.audio, asset: sourceAsset)
        let bakeB = direct.add(.print, ["bitDepth": .choice("32f")])
        direct.connect(source, to: bakeB)
        #expect(try await bake(wrapped, bakeA) == bake(direct, bakeB))
    }

    @Test func errorsInsideAreReportedOnTheCustomNode() {
        func errors(_ project: ProjectFile) -> [CompileError] {
            do { _ = try GraphCompiler.compile(project, assets: [sourceAsset: AssetInfo(frameCount: 12_000, channelCount: 2, sampleRate: 48_000)]); return [] }
            catch { return error.errors }
        }
        // Nothing wired into the custom node: its Filters inside has no input.
        var unwired = TestProject()
        let crunch = custom(&unwired, Self.chain)
        let bake = unwired.add(.print)
        unwired.project.edges.append(Edge(from: PinRef(node: crunch, pin: "out1"), to: PinRef(node: bake, pin: "in")))
        #expect(errors(unwired.project).map { error -> NodeID? in
            if case .missingInput(let pin) = error { pin.node } else { nil }
        } == [crunch])

        var missing = TestProject()
        let orphan = missing.add(.custom)
        missing.project.nodes[0].customDefinition = testUUID(69_999)
        let bake2 = missing.add(.print)
        missing.project.edges.append(Edge(from: PinRef(node: orphan, pin: "out1"), to: PinRef(node: bake2, pin: "in")))
        #expect(errors(missing.project) == [.missingCustomDefinition(orphan)])

        var nested = TestProject()
        var inner = Self.chain
        inner.nodes.append(Node(id: Self.id(99), kind: .custom))
        let outer = custom(&nested, inner)
        let bake3 = nested.add(.print)
        nested.project.edges.append(Edge(from: PinRef(node: outer, pin: "out1"), to: PinRef(node: bake3, pin: "in")))
        #expect(errors(nested.project) == [.nestedCustomNode(outer)])
    }

    @Test func documentsCarryTheirDefinitionsAndOldOnesOpenUnchanged() throws {
        var graph = TestProject()
        _ = custom(&graph, Self.chain, parameters: ["macro.1": .number(0.3)])
        let data = try JSONEncoder().encode(graph.project)
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: data)
        #expect(decoded == graph.project)
        #expect(decoded.customNodes == [Self.chain])
        // A schema 4 file has neither field.
        let old = #"{"schemaVersion": 4, "nodes": [{"id": "00000000-0000-0000-0000-000000000001", "kind": "filters", "position": {"x": 0, "y": 0}, "parameters": {}, "modulated": []}]}"#
        let project = try JSONDecoder().decode(ProjectFile.self, from: Data(old.utf8))
        #expect(project.customNodes.isEmpty && project.nodes[0].customDefinition == nil)
    }

    @Test func aCustomNodeShowsItsOutputLength() {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let crunch = custom(&graph, Self.chain)
        graph.connect(audio, to: crunch, "in1")
        let shapes = GraphCompiler.previewShapes(graph.project, assets: [sourceAsset: AssetInfo(frameCount: 12_000, channelCount: 2, sampleRate: 48_000)])
        #expect(shapes[crunch]?.frames == 12_000)
    }

    @Test func aProjectWithoutCustomNodesIsLeftAlone() {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let bake = graph.add(.print)
        graph.connect(audio, to: bake)
        #expect(CustomNodeFlattener.flatten(graph.project).project == graph.project)
    }
}

import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

/// Custom Nodes Phase B (spec §12): Group Selection and Ungroup, and the custom node's card interface.
struct CustomNodeEditingTests {
    /// Audio → Filters → Distortion → Bake, with an LFO on the Filters' Cutoff.
    private struct Patch {
        var graph = TestProject()
        let audio, lfo, filters, distortion, bake: NodeID

        init() {
            audio = graph.add(.audio, asset: sourceAsset)
            lfo = graph.add(.lfo, ["rate": .number(2)])
            filters = graph.add(.filters, ["cutoff": .number(600)], modulated: ["cutoff"])
            distortion = graph.add(.distortion, ["drive": .number(9)])
            bake = graph.add(.print, ["bitDepth": .choice("32f")])
            graph.connect(audio, to: filters)
            graph.connect(lfo, to: filters, "mod.cutoff")
            graph.connect(filters, to: distortion)
            graph.connect(distortion, to: bake)
            for (index, id) in [audio, lfo, filters, distortion, bake].enumerated() {
                graph.project.nodes[graph.project.index(of: id)!].position = CanvasPoint(x: Double(index) * 300, y: 100)
            }
        }
    }

    private func bake(_ project: ProjectFile, _ bake: NodeID) async throws -> [[Float]] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try TestAudio.write(TestAudio.samples(frames: 12_000, channels: 2), to: source, sampleRate: 48_000)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let urls = [sourceAsset: source]
        let request = RenderRequest(plan: try compile(project, assetURLs: urls), assetURLs: urls, outputDirectory: output)
        return try TestAudio.read(try #require(try await RenderEngine.render(request).outputs[bake])).samples
    }

    @Test(arguments: ["filters+distortion", "lfo+filters", "filters", "all but audio and bake"])
    func groupingNeverChangesTheSound(selection: String) async throws {
        let patch = Patch()
        let ids: Set<NodeID> = switch selection {
        case "filters+distortion": [patch.filters, patch.distortion]
        case "lfo+filters": [patch.lfo, patch.filters]
        case "filters": [patch.filters]
        default: [patch.lfo, patch.filters, patch.distortion]
        }
        var grouped = patch.graph.project
        let groupedID = grouped.groupNodes(ids)
        let custom = try #require(groupedID)
        #expect(grouped.node(custom)?.kind == .custom)
        #expect(grouped.nodes.count == patch.graph.project.nodes.count - ids.count + 1)
        #expect(try await bake(grouped, patch.bake) == bake(patch.graph.project, patch.bake))
    }

    @Test func ungroupGivesTheOriginalPatchBack() throws {
        let patch = Patch()
        var project = patch.graph.project
        let groupedID = project.groupNodes([patch.lfo, patch.filters, patch.distortion])
        let custom = try #require(groupedID)
        let restored = project.ungroup(custom)
        #expect(restored == [patch.lfo, patch.filters, patch.distortion])
        #expect(Set(project.nodes) == Set(patch.graph.project.nodes))
        #expect(Set(project.edges) == Set(patch.graph.project.edges))
        #expect(project.customNodes.isEmpty)
    }

    @Test func aControlWireIntoTheGroupMakesAControlPin() throws {
        let patch = Patch()
        var project = patch.graph.project
        let groupedID = project.groupNodes([patch.filters, patch.distortion])
        let custom = try #require(groupedID)
        let node = try #require(project.node(custom))
        let pins = NodeCatalog.pins(of: node, in: project)
        // Audio comes in on one pin and the LFO on another, in card order (both feed Filters).
        #expect(pins.filter { $0.direction == .input }.map(\.signal).sorted { $0.rawValue < $1.rawValue } == [.audio, .control])
        #expect(pins.filter { $0.direction == .output }.map(\.id) == ["out1"])
        // Ports are named after what they reach inside, in the order of their sources outside.
        #expect(NodeCatalog.label(of: "in1", on: node, in: project) == "Filters")
        #expect(NodeCatalog.label(of: "in2", on: node, in: project) == "Cutoff")
        #expect(NodeCatalog.label(of: "out1", on: node, in: project) == "Distortion")
        // The LFO stays wired to the custom node, and a new wire into the group is accepted.
        #expect(project.edges.contains { $0.from.node == patch.lfo && $0.to.node == custom })
        let other = project.addNode(.audio, at: CanvasPoint())
        let free = PinRef(node: custom, pin: "in1")
        project.edges.removeAll { $0.to == free }
        #expect(project.checkConnection(from: PinRef(node: other, pin: "out"), to: free) == nil)
    }

    @Test func macrosInsideBecomeTheCustomNodesControls() throws {
        var graph = TestProject()
        let audio = graph.add(.audio, asset: sourceAsset)
        let macro = graph.add(.macro, ["value": .number(0.4), "label": .text("Brightness")])
        let filters = graph.add(.filters, [:], modulated: ["cutoff"])
        let bake = graph.add(.print)
        graph.connect(audio, to: filters)
        graph.project.edges.append(Edge(from: PinRef(node: macro, pin: "out1"), to: PinRef(node: filters, pin: "mod.cutoff")))
        graph.connect(filters, to: bake)
        var project = graph.project
        let groupedID = project.groupNodes([macro, filters])
        let custom = try #require(groupedID)
        let node = try #require(project.node(custom))
        let controls = NodeCatalog.visibleParameters(of: node, in: project)
        #expect(controls.map(\.id) == ["macro.1"])
        #expect(controls.first?.name == "Brightness")
        #expect(NodeCatalog.resolvedParameters(of: node, in: project)["macro.1"] == .number(0.4))
        // Setting and modulating the control work like any parameter.
        project.setParameter("macro.1", of: custom, to: .number(0.9))
        #expect(project.node(custom)?.parameters["macro.1"] == .number(0.9))
        project.setModulated("macro.1", of: custom, true)
        let ticked = try #require(project.node(custom))
        #expect(NodeCatalog.pins(of: ticked, in: project).contains { $0.id == "mod.macro.1" })
    }

    @Test func outputsAndCustomNodesCantBeGrouped() throws {
        let patch = Patch()
        var project = patch.graph.project
        #expect(!project.canGroup([patch.bake]))
        #expect(!project.canGroup([]))
        let groupedID = project.groupNodes([patch.filters])
        let custom = try #require(groupedID)
        #expect(!project.canGroup([custom, patch.distortion]))
    }

    @Test func audioCantBeGroupedButAnOlderCustomNodeWithAudioKeepsItsFile() throws {
        let patch = Patch()
        var project = patch.graph.project
        #expect(!project.canGroup([patch.audio, patch.filters]))
        #expect(project.groupNodes([patch.audio, patch.filters]) == nil)
        // Custom nodes made before Audio was kept out may still hold one: it keeps its file.
        let grouped = project.groupNodes([patch.filters])
        _ = try #require(grouped)
        project.customNodes[0].nodes.append(Node(kind: .audio, assetID: sourceAsset))
        project.removeNodes([patch.audio])
        project.removeNodes([patch.lfo])
        #expect(project.assets.isEmpty == patch.graph.project.assets.isEmpty)
        #expect(project.customNodes.flatMap(\.nodes).contains { $0.assetID == sourceAsset })
    }

    @Test func editingInsideChangesEveryInstanceAndKeepsThePatchsFiles() async throws {
        let patch = Patch()
        var project = patch.graph.project
        let first = project.groupNodes([patch.filters, patch.distortion])
        let custom = try #require(first)
        let definition = try #require(project.node(custom)?.customDefinition)
        let before = try await bake(project, patch.bake)

        // Inside: raise the Distortion's drive; deleting nothing at the top must lose no files.
        var inside = try #require(project.inside(definition))
        inside.setParameter("drive", of: patch.distortion, to: .number(20))
        let extra = inside.addNode(.redux, at: CanvasPoint())
        inside.removeNodes([extra])
        project.storeInside(inside, into: definition)
        #expect(project.assets == patch.graph.project.assets)
        #expect(project.customNodes.first?.nodes.first { $0.id == patch.distortion }?.parameters["drive"] == .number(20))
        #expect(try await bake(project, patch.bake) != before)
    }

    @Test func removingAnOutputInsideDropsItsWires() throws {
        let patch = Patch()
        var project = patch.graph.project
        let first = project.groupNodes([patch.filters, patch.distortion])
        let custom = try #require(first)
        let definition = try #require(project.node(custom)?.customDefinition)
        #expect(project.edges.contains { $0.from == PinRef(node: custom, pin: "out1") })
        var inside = try #require(project.inside(definition))
        let output = try #require(inside.nodes.first { $0.kind == .customOutput })
        inside.removePort("out1", of: output.id)
        project.storeInside(inside, into: definition)
        #expect(!project.edges.contains { $0.from.node == custom && $0.from.pin == "out1" })
    }

    @Test func aDefinitionCanBeAddedAgain() throws {
        let patch = Patch()
        var project = patch.graph.project
        let first = project.groupNodes([patch.filters, patch.distortion])
        let custom = try #require(first)
        let definition = try #require(project.node(custom)?.customDefinition)
        let second = project.addCustomNode(definition, at: CanvasPoint(x: 0, y: 400))
        let added = try #require(second)
        #expect(NodeCatalog.pins(of: try #require(project.node(added)), in: project).map(\.id)
            == NodeCatalog.pins(of: try #require(project.node(custom)), in: project).filter { !$0.id.hasPrefix("mod.") }.map(\.id))
    }

    @Test func renamingAndReorderingPortsKeepsEveryWire() async throws {
        let patch = Patch()
        var project = patch.graph.project
        let first = project.groupNodes([patch.filters, patch.distortion])
        let custom = try #require(first)
        let definition = try #require(project.node(custom)?.customDefinition)
        let before = try await bake(project, patch.bake)
        let wires = Set(project.edges)

        var inside = try #require(project.inside(definition))
        let inputs = try #require(inside.nodes.first { $0.kind == .customInput })
        inside.renamePort("in2", of: inputs.id, to: "  Wobble ")
        inside.renamePort("in1", of: inputs.id, to: " ")
        inside.movePort("in2", of: inputs.id, by: -1)
        project.storeInside(inside, into: definition)

        let node = try #require(project.node(custom))
        #expect(NodeCatalog.pins(of: node, in: project).map(\.id) == ["in2", "in1", "out1"])
        #expect(NodeCatalog.label(of: "in2", on: node, in: project) == "Wobble")
        #expect(NodeCatalog.label(of: "in1", on: node, in: project) == "Filters")
        #expect(Set(project.edges) == wires)
        #expect(try await bake(project, patch.bake) == before)
    }

    @Test func wiringOntoTheSpareSlotExposesAPort() throws {
        let patch = Patch()
        var project = patch.graph.project
        let first = project.groupNodes([patch.filters, patch.distortion])
        let custom = try #require(first)
        let definition = try #require(project.node(custom)?.customDefinition)

        var inside = try #require(project.inside(definition))
        let inputs = try #require(inside.nodes.first { $0.kind == .customInput })
        let outputs = try #require(inside.nodes.first { $0.kind == .customOutput })
        #expect(NodeCatalog.spareBoundaryPin(of: inputs) == "in3")
        #expect(NodeCatalog.spareBoundaryPin(of: outputs) == "out2")
        inside.setModulated("drive", of: patch.distortion, true)
        try inside.connect(from: PinRef(node: inputs.id, pin: "in3"), to: PinRef(node: patch.distortion, pin: "mod.drive"))
        try inside.connect(from: PinRef(node: patch.filters, pin: "out"), to: PinRef(node: outputs.id, pin: "out2"))
        // Inside, the port carries what it does outside: control into Drive, audio from Filters.
        #expect(inside.pin(PinRef(node: inputs.id, pin: "in3"))?.signal == .control)
        #expect(inside.pin(PinRef(node: outputs.id, pin: "out2"))?.signal == .audio)
        project.storeInside(inside, into: definition)

        let node = try #require(project.node(custom))
        let pins = NodeCatalog.pins(of: node, in: project)
        #expect(pins.map(\.id) == ["in1", "in2", "in3", "out1", "out2"])
        #expect(pins.first { $0.id == "in3" }?.signal == .control)
        #expect(NodeCatalog.label(of: "in3", on: node, in: project) == "Drive")
        #expect(NodeCatalog.label(of: "out2", on: node, in: project) == "Filters")
        // The new output works outside: it's what Filters makes.
        let flat = CustomNodeFlattener.flatten(project)
        let source = try #require(flat.outputs[custom]?["out2"])
        #expect(flat.project.node(source.node)?.kind == .filters)
        #expect(flat.origin[source.node] == custom)
    }

    @Test func aPromotedParameterIsTheCustomNodesOwnControl() async throws {
        let patch = Patch()
        var project = patch.graph.project
        let first = project.groupNodes([patch.filters, patch.distortion])
        let custom = try #require(first)
        let definition = try #require(project.node(custom)?.customDefinition)
        var inside = try #require(project.inside(definition))
        inside.setPromoted("drive", of: patch.distortion, true)
        project.storeInside(inside, into: definition)

        let control = CustomNodeDefinition.promotedParameter("drive", of: patch.distortion)
        let node = try #require(project.node(custom))
        let parameter = try #require(NodeCatalog.parameter(control, of: node, in: project))
        #expect(parameter.name == "Drive")
        #expect(parameter.isModulatable)
        #expect(NodeCatalog.resolvedParameters(of: node, in: project)[control] == .number(9))
        #expect(CustomNodeDefinition.promotedTarget(of: control)?.node == patch.distortion)

        // Turning it up on the custom node sounds like turning it up inside.
        project.setParameter(control, of: custom, to: .number(20))
        var direct = patch.graph.project
        direct.setParameter("drive", of: patch.distortion, to: .number(20))
        #expect(try await bake(project, patch.bake) == bake(direct, patch.bake))

        // Hiding it again drops its modulation wire outside.
        project.setModulated(control, of: custom, true)
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        try project.connect(from: PinRef(node: lfo, pin: "out"), to: PinRef(node: custom, pin: NodeCatalog.modulationPinID(for: control)))
        var hide = try #require(project.inside(definition))
        hide.setPromoted("drive", of: patch.distortion, false)
        project.storeInside(hide, into: definition)
        #expect(!project.edges.contains { $0.from.node == lfo })
    }

    @Test func definitionsWithOneCardPerPinAreMerged() {
        let a = NodeID(testUUID(70_001)), b = NodeID(testUUID(70_002)), mixer = NodeID(testUUID(70_003))
        let c = NodeID(testUUID(70_004))
        let definition = CustomNodeDefinition(
            name: "Old",
            nodes: [
                Node(id: a, kind: .customInput, parameters: ["name": .text("Left")]),
                Node(id: b, kind: .customInput),
                Node(id: mixer, kind: .mixer),
                Node(id: c, kind: .customOutput),
            ],
            edges: [
                Edge(from: PinRef(node: a, pin: "out"), to: PinRef(node: mixer, pin: "in1")),
                Edge(from: PinRef(node: b, pin: "out"), to: PinRef(node: mixer, pin: "in2")),
                Edge(from: PinRef(node: mixer, pin: "out"), to: PinRef(node: c, pin: "in")),
            ]
        )
        #expect(definition.nodes.map(\.id) == [a, mixer, c])
        #expect(definition.inputPorts == [CustomPort(id: "in1", name: "Left"), CustomPort(id: "in2", name: "In 2")])
        #expect(definition.outputPorts == [CustomPort(id: "out1", name: "Out 1")])
        #expect(Set(definition.edges) == [
            Edge(from: PinRef(node: a, pin: "in1"), to: PinRef(node: mixer, pin: "in1")),
            Edge(from: PinRef(node: a, pin: "in2"), to: PinRef(node: mixer, pin: "in2")),
            Edge(from: PinRef(node: mixer, pin: "out"), to: PinRef(node: c, pin: "out1")),
        ])
    }
}

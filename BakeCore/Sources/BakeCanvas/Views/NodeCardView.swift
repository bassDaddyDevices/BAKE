import AppKit
import BakeGraph
import SwiftUI

/// One node card. Header and pins stay fixed; only the body flips between Page 1 (macro controls)
/// and Page 2 (modulation + settings), so wires never move when a card flips.
struct NodeCardView: View, Equatable {
    let node: Node
    let isSelected: Bool
    /// Problems the last bake found on this node, and on which of its pins.
    let issues: [String]
    let issuePins: Set<PinID>
    /// For Audio nodes: the file they play, and whether it can't be found or read.
    let fileName: String?
    var isFileMissing = false
    /// How long this node's output will be, when it can be worked out.
    let outputSeconds: Double?
    /// For Bake nodes: the folder they write into.
    let folderName: String?
    /// Batch Audio: how many files its folder has (nil: the folder isn't there). Batch Bake: how many it writes.
    var batchFileCount: Int? = nil
    /// Combinatorial Matrix: how many files each of A, B and C steps through in a batch (empty: no batch).
    var combinationCounts: [Int] = []
    /// Large Audio Processor: where its slices start, as fractions of its file.
    var sliceMarks: [Double] = []
    /// Batch Bake: the file its first pass will write.
    var firstFileName: String? = nil
    let isBaking: Bool
    /// Audio nodes: their source; Preview nodes: their last render.
    let waveform: WaveformPeaks?
    let isPlaying: Bool
    /// What this node produced in the last bake, and whether the graph has changed since.
    var summary: NodeSummary? = nil
    var isSummaryStale = false
    /// The last bake of what is wired into this node (Math's A and B, the Envelope's trigger).
    var inputSummaries: [PinID: NodeSummary] = [:]
    /// The last bake of each of this node's own outputs, by pin (the Pitch Follower draws two).
    var outputSummaries: [PinID: NodeSummary] = [:]
    /// Custom nodes: their definition, which sets their title, pins and controls.
    var definition: CustomNodeDefinition? = nil
    @Binding var project: ProjectFile
    let model: CanvasModel
    /// Not part of `==`: closures from the app don't change what the card shows.
    let actions: NodeActions

    /// Position is applied by the workspace, so moving a card doesn't re-render its contents.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isSelected == rhs.isSelected && lhs.node.id == rhs.node.id && lhs.node.kind == rhs.node.kind
            && lhs.node.parameters == rhs.node.parameters && lhs.node.modulated == rhs.node.modulated
            && lhs.node.modulationTrims == rhs.node.modulationTrims && lhs.node.assetID == rhs.node.assetID
            && lhs.issues == rhs.issues && lhs.issuePins == rhs.issuePins && lhs.fileName == rhs.fileName
            && lhs.outputSeconds == rhs.outputSeconds && lhs.node.outputFolder == rhs.node.outputFolder
            && lhs.folderName == rhs.folderName && lhs.isBaking == rhs.isBaking
            && lhs.batchFileCount == rhs.batchFileCount && lhs.combinationCounts == rhs.combinationCounts && lhs.node.sourceFolder == rhs.node.sourceFolder
            && lhs.sliceMarks == rhs.sliceMarks && lhs.firstFileName == rhs.firstFileName
            && lhs.waveform == rhs.waveform && lhs.isPlaying == rhs.isPlaying
            && lhs.summary == rhs.summary && lhs.isSummaryStale == rhs.isSummaryStale
            && lhs.inputSummaries == rhs.inputSummaries && lhs.outputSummaries == rhs.outputSummaries
            && lhs.definition == rhs.definition && lhs.isFileMissing == rhs.isFileMissing && lhs.node.ports == rhs.node.ports && lhs.node.promoted == rhs.node.promoted
    }

    private var title: String { definition?.name ?? node.kind.title }
    /// Modulation sources, and custom nodes whose every output is control, wear the control colour.
    private var isModulationSource: Bool {
        if let outputs = definition?.interface.outputs, !outputs.isEmpty { return outputs.allSatisfy { $0.signal == .control } }
        return node.kind.isModulationSource
    }
    private var cardColor: Color { isModulationSource ? SignalType.control.color : .accentColor }
    private var isBoundary: Bool { node.kind == .customInput || node.kind == .customOutput }

    var body: some View {
        let flipped = model.page(of: node.id) == .modulation
        VStack(spacing: 0) {
            header(flipped: flipped)
            PortRows(node: node, issuePins: issuePins, project: $project, model: model)
            Divider()
            // Below the pins, so pin anchors never move.
            if !issues.isEmpty { IssueList(issues: issues) }
            if isBoundary {
                Text(node.kind == .customInput
                     ? "Wire from + to add an input. Double-click a name to rename it; right-click to reorder."
                     : "Wire onto + to add an output. Double-click a name to rename it; right-click to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            } else {
                pages(flipped: flipped)
            }
            if let outputSeconds { OutputLengthRow(seconds: outputSeconds, isModulationSource: isModulationSource) }
        }
        .frame(width: NodeLayout.width)
        // Sliders, menus and the card's pictures follow it, so modulation sources read teal throughout.
        .tint(cardColor)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isSelected || !issues.isEmpty ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            Button("Select") { model.select(node.id, extending: false) }
            Button(flipped ? "Show Controls Page" : "Show Modulation Page") { model.flip(node.id) }
            if node.kind == .custom, let editInside = actions.editInside { Button("Edit Inside") { editInside(node.id) } }
            if !isBoundary { Button("Delete") { $project.edit { $0.removeNodes([node.id]) } } }
        }
        .accessibilityIdentifier("node.\(node.kind.rawValue)")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if node.kind == .batchAudio, url.hasDirectoryPath, let useSourceFolder = actions.useSourceFolder {
                useSourceFolder(node.id, url)
                return true
            }
            guard node.kind == .audio || node.kind == .largeAudio, let importAudio = actions.importAudio else { return false }
            importAudio(node.id, url)
            return true
        }
    }

    /// Only the shown page exists, and it rests unrotated: AppKit-backed controls (sliders, menus, text
    /// fields) miss clicks under a 3D rotation, and a hidden page's controls can swallow them. The turn
    /// is a transition, so rotation only exists while the card is flipping.
    private func pages(flipped: Bool) -> some View {
        ZStack(alignment: .top) {
            if flipped {
                ModulationPage(node: node, project: $project, model: model, inputSummaries: inputSummaries)
                    .transition(.flipFace)
            } else {
                MacroPage(
                    node: node, fileName: fileName, isFileMissing: isFileMissing, folderName: folderName,
                    batchFileCount: batchFileCount, combinationCounts: combinationCounts, sliceMarks: sliceMarks, firstFileName: firstFileName, waveform: waveform, isPlaying: isPlaying,
                    summary: summary, isSummaryStale: isSummaryStale, inputSummaries: inputSummaries,
                    outputSummaries: outputSummaries, actions: actions, project: $project, model: model
                )
                    .transition(.flipFace)
            }
        }
        .padding(10)
        .animation(.smooth(duration: 0.35), value: flipped)
    }

    /// Selected: the card's colour. Unselected: red for problems, else faint — tinted on modulation sources.
    private var borderColor: Color {
        if isSelected { return cardColor }
        if !issues.isEmpty { return .red }
        return isModulationSource ? cardColor.opacity(0.6) : .secondary.opacity(0.35)
    }

    private func header(flipped: Bool) -> some View {
        HStack(spacing: 8) {
            // Red when the last bake found a problem here; modulation sources show the control colour.
            Circle()
                .fill(!issues.isEmpty ? Color.red : isModulationSource ? cardColor : Color.secondary)
                .frame(width: 8, height: 8)
            Text(title).font(.headline)
            Spacer()
            if !isBoundary {
                Button(flipped ? "P2" : "P1") { model.flip(node.id) }
                    .buttonStyle(.borderless)
                    .font(.caption.monospaced())
                    .help(flipped ? "Show Page 1 (controls)" : "Show Page 2 (modulation)")
                    .accessibilityLabel(flipped ? "Show controls page" : "Show modulation page")
                    .accessibilityIdentifier("flip")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NodeLayout.headerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasSpace.name))
                .onChanged { model.dragNode(node.id, by: $0.translation) }
                .onEnded { _ in $project.edit { model.endNodeDrag(in: &$0) } }
        )
        .onTapGesture { model.select(node.id, extending: NSEvent.modifierFlags.contains(.shift)) }
        // Double-clicking a custom node's header opens it (Edit Inside).
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if node.kind == .custom { actions.editInside?(node.id) }
        })
        .help(node.kind == .custom ? "Double-click to edit what's inside" : "")
    }
}

/// One face of the card turning edge-on (90°) and fading as it leaves, or turning back in from the other edge.
private struct FlipFace: ViewModifier {
    let angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .opacity(angle == 0 ? 1 : 0)
    }
}

private extension AnyTransition {
    static var flipFace: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: FlipFace(angle: -90), identity: FlipFace(angle: 0)),
            removal: .modifier(active: FlipFace(angle: 90), identity: FlipFace(angle: 0))
        )
    }
}

#Preview("Filters card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let filters = project.addNode(.filters, at: CanvasPoint())
        project.setModulated("cutoff", of: filters, true)
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: ["Needs an input."], issuePins: ["in"], fileName: nil, outputSeconds: 1_000,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(), actions: NodeActions()
    )
        .padding(30)
}

#Preview("Bake card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        project.addNode(.print, at: CanvasPoint())
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: 25.6,
        folderName: "Default: Bounces", isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions(chooseFolder: { _ in }, bake: { _ in })
    )
        .padding(30)
}

#Preview("Preview card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        project.addNode(.preview, at: CanvasPoint())
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: 12,
        folderName: nil, isBaking: false,
        waveform: WaveformPeaks(peaks: (0..<160).map { Float(abs(sin(Double($0) * 0.21)) * (1 - Double($0) / 200)) }),
        isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions(preview: { _ in }, stopPreview: {})
    )
        .padding(30)
}

#Preview("LFO card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let lfo = project.addNode(.lfo, at: CanvasPoint())
        project.setParameter("shape", of: lfo, to: .choice("triangle"))
        project.setParameter("depth", of: lfo, to: .number(0.7))
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

#Preview("Custom node card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let lfo = project.addNode(.lfo, at: CanvasPoint(y: 200))
        let macro = project.addNode(.macro, at: CanvasPoint(x: 300, y: 200))
        project.setParameter("label", of: macro, to: .text("Bite"))
        project.setParameter("value", of: macro, to: .number(0.6))
        let filters = project.addNode(.filters, at: CanvasPoint(x: 300))
        project.setModulated("cutoff", of: filters, true)
        project.setModulated("q", of: filters, true)
        let distortion = project.addNode(.distortion, at: CanvasPoint(x: 600))
        let bake = project.addNode(.print, at: CanvasPoint(x: 900))
        try? project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try? project.connect(from: PinRef(node: lfo, pin: "out"), to: PinRef(node: filters, pin: "mod.cutoff"))
        try? project.connect(from: PinRef(node: macro, pin: "out1"), to: PinRef(node: filters, pin: "mod.q"))
        try? project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: distortion, pin: "in"))
        try? project.connect(from: PinRef(node: distortion, pin: "out"), to: PinRef(node: bake, pin: "in"))
        project.groupNodes([macro, filters, distortion], name: "Crunch")
        return project
    }()
    let custom = project.nodes.first { $0.kind == .custom }!
    NodeCardView(
        node: custom, isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: 4,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, definition: project.definition(of: custom),
        project: $project, model: CanvasModel(), actions: NodeActions()
    )
    .padding(30)
}

#Preview("Macro cards") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        for value in [0.0, 0.35, 1.0] {
            let macro = project.addNode(.macro, at: CanvasPoint())
            project.setParameter("value", of: macro, to: .number(value))
        }
        return project
    }()
    HStack(alignment: .top, spacing: 20) {
        ForEach(project.nodes) { node in
            NodeCardView(
                node: node, isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
                folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
                actions: NodeActions()
            )
        }
    }
    .padding(30)
}

#Preview("Mixer and Splitter cards") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let mixer = project.addNode(.mixer, at: CanvasPoint())
        try? project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: mixer, pin: "in2"))
        let splitter = project.addNode(.channelSplitter, at: CanvasPoint())
        project.setParameter("channels", of: splitter, to: .choice("4"))
        return project
    }()
    HStack(alignment: .top, spacing: 30) {
        ForEach(project.nodes.dropFirst()) { node in
            NodeCardView(
                node: node, isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
                folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
                actions: NodeActions()
            )
        }
    }
    .padding(30)
}

#Preview("Clock card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        project.addNode(.clock, at: CanvasPoint())
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

/// A made-up control summary for previews.
private func control(_ detail: [Float]) -> NodeSummary {
    NodeSummary(sampleRate: 48_000, frames: 48_000 * 60, channels: 1, isControl: true,
                minimums: [detail.min() ?? 0], maximums: [detail.max() ?? 0], rms: [0.5], spectrogram: nil, detail: detail)
}

#Preview("Math and Envelope after a bake") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let math = project.addNode(.math, at: CanvasPoint())
        project.setParameter("operator", of: math, to: .choice("multiply"))
        project.addNode(.envelope, at: CanvasPoint())
        return project
    }()
    // Made-up last bake: a 0.5 Hz LFO on A, 120 BPM quarter-note bangs on B, and an Envelope on those bangs.
    let points = Int(NodeSummary.detailSeconds * NodeSummary.detailRate)
    let lfo = (0..<points).map { Float(sin(Double($0) / NodeSummary.detailRate * .pi)) }
    let bangs = (0..<points).map { Float($0 % 125 < 13 ? 1 : 0) }
    let envelope = (0..<points).map { Float(exp(-Double($0 % 125) / 30)) }
    HStack(alignment: .top, spacing: 30) {
        NodeCardView(
            node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
            folderName: nil, isBaking: false, waveform: nil, isPlaying: false,
            summary: control(zip(lfo, bangs).map(*)), inputSummaries: ["a": control(lfo), "b": control(bangs)],
            project: $project, model: CanvasModel(), actions: NodeActions()
        )
        NodeCardView(
            node: project.nodes[1], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
            folderName: nil, isBaking: false, waveform: nil, isPlaying: false,
            summary: control(envelope), inputSummaries: ["trigger": control(bangs)],
            project: $project, model: CanvasModel(), actions: NodeActions()
        )
    }
    .padding(30)
}

#Preview("Envelope Follower card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        project.addNode(.envelopeFollower, at: CanvasPoint())
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

#Preview("Switch card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let router = project.addNode(.stepSwitch, at: CanvasPoint())
        project.setParameter("order", of: router, to: .choice("pingPong"))
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

#Preview("Half Time card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        project.addNode(.halfTime, at: CanvasPoint())
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

#Preview("Beat Repeat card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let repeater = project.addNode(.beatRepeat, at: CanvasPoint())
        project.setParameter("accelerate", of: repeater, to: .number(0.8))
        project.setParameter("decay", of: repeater, to: .number(0.1))
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

#Preview("Looper card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let looper = project.addNode(.looper, at: CanvasPoint())
        project.setParameter("passes", of: looper, to: .number(8))
        project.setParameter("shrink", of: looper, to: .number(0.8))
        project.setParameter("direction", of: looper, to: .choice("pingPong"))
        project.setParameter("decay", of: looper, to: .number(0.1))
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

#Preview("Stutter card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        let stutter = project.addNode(.stutter, at: CanvasPoint())
        project.setParameter("shrink", of: stutter, to: .number(0.85))
        project.setParameter("gate", of: stutter, to: .number(0.6))
        project.setParameter("decay", of: stutter, to: .number(0.08))
        project.setParameter("panDrift", of: stutter, to: .number(0.4))
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

#Preview("Step FX card") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        project.addNode(.stepFX, at: CanvasPoint())
        return project
    }()
    NodeCardView(
        node: project.nodes[0], isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
        folderName: nil, isBaking: false, waveform: nil, isPlaying: false, project: $project, model: CanvasModel(),
        actions: NodeActions()
    )
        .padding(30)
}

#Preview("Modulated controls, before and after a bake") {
    @Previewable @State var project: ProjectFile = {
        var project = ProjectFile()
        for x in [0.0, 300] {
            let filters = project.addNode(.filters, at: CanvasPoint(x: x, y: 0))
            project.setModulated("cutoff", of: filters, true)
            project.setTrim(0.3, for: "cutoff", of: filters)
            project.setModulated("type", of: filters, true)
            project.setTrim(0.5, for: "type", of: filters)
        }
        return project
    }()
    // A 0.5 Hz LFO over the 4-second trace.
    let lfo = (0..<1_000).map { Float(sin(2 * Double.pi * 0.5 * Double($0) / 250)) }
    HStack(alignment: .top, spacing: 20) {
        ForEach(Array(project.nodes.enumerated()), id: \.offset) { index, node in
            NodeCardView(
                node: node, isSelected: false, issues: [], issuePins: [], fileName: nil, outputSeconds: nil,
                folderName: nil, isBaking: false, waveform: nil, isPlaying: false,
                inputSummaries: index == 1 ? ["mod.cutoff": control(lfo), "mod.type": control(lfo)] : [:],
                project: $project, model: CanvasModel(), actions: NodeActions()
            )
        }
    }
    .padding(30)
}

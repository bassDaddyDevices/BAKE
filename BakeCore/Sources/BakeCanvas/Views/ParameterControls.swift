import BakeGraph
import SwiftUI
import UniformTypeIdentifiers

/// Pins on the card edges, one row each at `NodeLayout` positions.
struct PortRows: View {
    let node: Node
    let issuePins: Set<PinID>
    @Binding var project: ProjectFile
    let model: CanvasModel

    var body: some View {
        let slots = NodeLayout.ports(of: node, in: project)
        VStack(spacing: 0) {
            ForEach(0..<NodeLayout.portRows(of: node, in: project), id: \.self) { row in
                HStack(spacing: 6) {
                    if let slot = slots.first(where: { $0.side == .left && $0.row == row }) {
                        PinDot(pin: PinRef(node: node.id, pin: slot.pin.id), signal: slot.pin.signal, hasIssue: issuePins.contains(slot.pin.id), project: $project, model: model)
                            .offset(x: -NodeLayout.pinRadius)
                            .accessibilityLabel("\(NodeCatalog.label(of: slot.pin.id, on: node, in: project)) input")
                        label(for: slot)
                    }
                    Spacer(minLength: 4)
                    if let slot = slots.first(where: { $0.side == .right && $0.row == row }) {
                        label(for: slot)
                        PinDot(pin: PinRef(node: node.id, pin: slot.pin.id), signal: slot.pin.signal, hasIssue: issuePins.contains(slot.pin.id), project: $project, model: model)
                            .offset(x: NodeLayout.pinRadius)
                            .accessibilityLabel("\(NodeCatalog.label(of: slot.pin.id, on: node, in: project)) output")
                    }
                }
                .frame(height: NodeLayout.portRowHeight)
            }
        }
    }

    @ViewBuilder
    private func label(for slot: PortSlot) -> some View {
        if node.kind == .customInput || node.kind == .customOutput {
            BoundaryPortLabel(card: node, pin: slot.pin.id, project: $project)
        } else if let parameter = NodeCatalog.parameter(forModulationPin: slot.pin.id),
           let definition = NodeCatalog.parameter(parameter, of: node, in: project) {
            Text(definition.name).font(.caption)
            TrimKnob(
                value: node.modulationTrims[parameter] ?? 1,
                onChange: { model.previewTrim($0, for: parameter, of: node.id) },
                onCommit: { $project.edit { model.commitTrim(in: &$0) } }
            )
        } else {
            Text(NodeCatalog.label(of: slot.pin.id, on: node, in: project)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A port on an Inputs or Outputs card: double-click to rename it, right-click to move or remove it.
/// The last row is the spare: a wire onto it adds a port.
private struct BoundaryPortLabel: View {
    let card: Node
    let pin: PinID
    @Binding var project: ProjectFile
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let ports = card.ports ?? []
        if let index = ports.firstIndex(where: { $0.id == pin }) {
            Group {
                if isRenaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(maxWidth: 150)
                        .multilineTextAlignment(card.kind == .customInput ? .trailing : .leading)
                        .focused($isFocused)
                        .onAppear { isFocused = true }
                        .onSubmit(commit)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: isFocused) { if !isFocused { commit() } }
                } else {
                    Text(ports[index].name)
                        .font(.caption)
                        .onTapGesture(count: 2, perform: startRenaming)
                }
            }
            .contextMenu {
                Button("Rename", action: startRenaming)
                Button("Move Up") { $project.edit { $0.movePort(pin, of: card.id, by: -1) } }
                    .disabled(index == 0)
                Button("Move Down") { $project.edit { $0.movePort(pin, of: card.id, by: 1) } }
                    .disabled(index == ports.count - 1)
                Divider()
                Button("Remove", role: .destructive) { $project.edit { $0.removePort(pin, of: card.id) } }
            }
            .help("Double-click to rename; right-click to move or remove")
            .accessibilityElement(children: .combine)
            .accessibilityHint("Actions: rename, move, remove")
            .accessibilityActions {
                Button("Rename", action: startRenaming)
                if index > 0 { Button("Move Up") { $project.edit { $0.movePort(pin, of: card.id, by: -1) } } }
                if index < ports.count - 1 { Button("Move Down") { $project.edit { $0.movePort(pin, of: card.id, by: 1) } } }
                Button("Remove") { $project.edit { $0.removePort(pin, of: card.id) } }
            }
        } else {
            Text("+")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
                .help(card.kind == .customInput ? "Drag a wire from here to add an input" : "Drag a wire here to add an output")
        }
    }

    private func startRenaming() {
        draft = card.ports?.first { $0.id == pin }?.name ?? ""
        isRenaming = true
    }

    private func commit() {
        guard isRenaming else { return }
        isRenaming = false
        $project.edit { $0.renamePort(pin, of: card.id, to: draft) }
    }
}

/// A pin. Drag from it to draw a wire; drag from a wired input to pick up that wire.
struct PinDot: View {
    let pin: PinRef
    let signal: SignalType
    let hasIssue: Bool
    @Binding var project: ProjectFile
    let model: CanvasModel

    var body: some View {
        let highlight = model.highlight(of: pin)
        Circle()
            .fill(signal.color.opacity(highlight == .unavailable ? 0.25 : 1))
            .overlay(Circle().strokeBorder(.white, lineWidth: highlight == .target ? 2 : 0))
            .overlay(Circle().strokeBorder(.red, lineWidth: hasIssue ? 2 : 0))
            .frame(width: NodeLayout.pinRadius * 2, height: NodeLayout.pinRadius * 2)
            .scaleEffect(highlight == .target ? 1.35 : highlight == .candidate ? 1.15 : 1)
            .contentShape(Circle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasSpace.name))
                    .onChanged { model.dragWire(from: pin, toView: $0.location, in: project) }
                    .onEnded { _ in $project.edit { model.endWire(in: &$0) } }
            )
            // Without a drag (VoiceOver): activate one pin, then the other, to wire them.
            .accessibilityElement()
            .accessibilityIdentifier("pin.\(pin.pin)")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(connection)
            .accessibilityHint(model.wireStart == nil ? "Activate, then activate another pin to connect them" : "Activate to connect to the chosen pin")
            .accessibilityAction { $project.edit { model.activatePin(pin, in: &$0) } }
            .accessibilityActions {
                if project.edge(into: pin) != nil {
                    Button("Disconnect") { $project.edit { model.disconnect(pin, in: &$0) } }
                }
            }
    }

    /// What VoiceOver says about the pin's wires: where an input comes from, or how many an output feeds.
    private var connection: String {
        if model.wireStart == pin { return "chosen, waiting for the other end" }
        if let edge = project.edge(into: pin), let source = project.node(edge.from.node) {
            let title = project.definition(of: source)?.name ?? source.kind.title
            return "connected from \(title)"
        }
        let count = project.edges.count { $0.from == pin }
        return count == 0 ? "not connected" : count == 1 ? "feeds 1 input" : "feeds \(count) inputs"
    }
}

/// Page 1: the node's macro controls.
struct MacroPage: View {
    let node: Node
    let fileName: String?
    var isFileMissing = false
    let folderName: String?
    var batchFileCount: Int? = nil
    var combinationCounts: [Int] = []
    var sliceMarks: [Double] = []
    var firstFileName: String? = nil
    let waveform: WaveformPeaks?
    let isPlaying: Bool
    let summary: NodeSummary?
    let isSummaryStale: Bool
    /// Last-bake summaries of what is wired into this node's inputs (see `CardInputs`).
    var inputSummaries: [PinID: NodeSummary] = [:]
    /// Last-bake summaries of this node's own outputs, by pin.
    var outputSummaries: [PinID: NodeSummary] = [:]
    let actions: NodeActions
    @Binding var project: ProjectFile
    let model: CanvasModel

    var body: some View {
        let values = NodeCatalog.resolvedParameters(of: node, in: project)
        VStack(alignment: .leading, spacing: 8) {
            if node.kind == .lfo {
                let shape: String = if case .choice(let choice)? = values["shape"] { choice } else { "sine" }
                LFOShapeView(
                    shape: shape, depth: values["depth"]?.numberValue ?? 1,
                    phase: values["phase"]?.numberValue ?? 0, seed: Int(values["seed"]?.numberValue ?? 0),
                    rate: values["rate"]?.numberValue ?? 1,
                    overLength: values["sync"] == .choice("overLength"),
                    cycles: values["cycles"]?.numberValue ?? 1
                )
            }
            if node.kind == .stepFX {
                let pattern: String = if case .text(let text)? = values["pattern"] { text } else { "" }
                StepCellsView(node: node.id, pattern: pattern, steps: Int((values["steps"]?.numberValue ?? 16).rounded()), project: $project)
            }
            NodeVisualView(kind: node.kind, values: values, summary: summary, inputs: inputSummaries, outputs: outputSummaries)
            if node.kind == .audio {
                AudioFileRow(
                    node: node.id, fileName: fileName, isMissing: isFileMissing, choose: actions.chooseAudio, locate: actions.locateAudio
                )
                if let waveform { WaveformView(peaks: waveform) }
            }
            if node.kind == .preview {
                if let waveform { WaveformView(peaks: waveform) }
                Button(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill") {
                    if isPlaying { actions.stopPreview?() } else { actions.preview?(node.id) }
                }
                .controlSize(.small)
                .disabled(actions.preview == nil || (actions.isBaking && !isPlaying))
                .help(isPlaying ? "Stop playing" : "Render this point of the chain and play it")
                .accessibilityIdentifier("previewPlay")
            }
            if node.kind == .largeAudio {
                AudioFileRow(
                    node: node.id, fileName: fileName, isMissing: isFileMissing, choose: actions.chooseAudio, locate: actions.locateAudio
                )
                if let waveform {
                    WaveformView(peaks: waveform)
                        .overlay { SliceMarks(marks: sliceMarks) }
                }
                if fileName != nil, !isFileMissing {
                    Text(Self.sliceCountText(batchFileCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if node.kind == .corpusScatter {
                ScatterOnsets(grains: ScatterOnsets.grains(values, clips: batchFileCount ?? 0))
                    .frame(height: 28)
            }
            if node.kind == .forEachSplitter {
                Text(Self.splitterText(values, passes: batchFileCount ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if node.kind == .batchConform {
                Text(Self.conformText(values))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if node.kind == .photoBooth {
                Text(Self.boothText(values, count: batchFileCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if node.kind == .merryGoRound {
                Text(Self.dealText(values, passes: batchFileCount ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if node.kind == .spectralSorter {
                Text(Self.sorterText(values))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if node.kind == .combinatorialMatrix {
                Text(Self.combinationsText(combinationCounts))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if node.kind.isGather {
                let wired = project.edges.filter { $0.to.node == node.id && $0.to.pin.hasPrefix("in") }.count
                Text(Self.gatherText(node.kind, batchFileCount, inputs: wired))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if node.kind == .batchAudio {
                BatchFolderRow(node: node.id, folderName: fileName, fileCount: batchFileCount, choose: actions.chooseSourceFolder)
                // The first file, which Preview and the card lengths use.
                if let waveform { WaveformView(peaks: waveform) }
            }
            if node.kind == .print || node.kind == .batchBake {
                BakeFolderRow(node: node.id, folderName: folderName, actions: actions)
            }
            ForEach(NodeCatalog.visibleParameters(of: node, in: project).filter { $0.role == .macro }, id: \.id) { parameter in
                ParameterControl(
                    parameter: parameter, value: values[parameter.id], node: node.id, project: $project, model: model,
                    modulation: ControlModulation.of(parameter.id, on: node, inputs: inputSummaries)
                )
            }
            if node.kind == .custom, NodeCatalog.parameters(of: node, in: project).isEmpty {
                Text("Double-click the title to edit inside. Controls ticked there on Page 2 show here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Audio and Preview nodes already show their waveform above; every other node shows what it made.
            if let summary, node.kind != .audio, !node.kind.isBatchSource, !node.kind.isOutput {
                // The Envelope marks each trigger it received.
                let ticks = node.kind == .envelope ? ControlTrace.rises(inputSummaries["trigger"]?.detail ?? []) : []
                RenderedOutputView(summary: summary, isStale: isSummaryStale, triggerTicks: ticks)
            }
            if let firstFileName {
                Text("First file: \(firstFileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if node.kind == .print || node.kind == .batchBake {
                // Last, after the folder and file name it uses.
                let isBatch = node.kind == .batchBake
                Button(isBatch ? Self.bakeFilesTitle(batchFileCount) : "Bake", systemImage: "flame") { actions.bake?(node.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(actions.bake == nil || actions.isBaking || (isBatch && batchFileCount == 0))
                    .help(isBatch ? "Bake one file for each file of the Batch Audio feeding it" : "Bake just this node's file")
                    .accessibilityIdentifier("bakeNode")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MacroPage {
    /// Nil: not known before a bake (a Photo Booth on a wired trigger).
    static func bakeFilesTitle(_ count: Int?) -> String {
        guard let count else { return "Bake Files" }
        return count == 1 ? "Bake 1 File" : "Bake \(count) Files"
    }

    /// What a Batch Conform does to each file of its batch ("Every file → 120 BPM, C").
    nonisolated static func conformText(_ values: [ParameterID: ParameterValue]) -> String {
        let mode = values["conform"].flatMap { if case .choice(let v) = $0 { v } else { nil } } ?? "tempoKey"
        let bpm = values["targetBPM"]?.numberValue ?? 120
        let tempo = (bpm.rounded() == bpm ? String(Int(bpm)) : String(format: "%.1f", bpm)) + " BPM"
        let key = values["targetKey"].flatMap { if case .choice(let v) = $0 { v } else { nil } } ?? "C"
        let target = switch mode {
        case "tempo": tempo
        case "key": key
        default: "\(tempo), \(key)"
        }
        return "Every file → \(target)"
    }

    /// A Photo Booth's chunks before a bake: counted on its own grid, or waiting on its trigger.
    nonisolated static func boothText(_ values: [ParameterID: ParameterValue], count: Int?) -> String {
        guard let count else { return "A chunk at each trigger." }
        let every = values["every"] == .choice("ms")
            ? "\(Int(values["everyMs"]?.numberValue ?? 250)) ms"
            : "\(values["every"].flatMap { if case .choice(let v) = $0 { v } else { nil } } ?? "1/4") at \(Int(values["bpm"]?.numberValue ?? 120)) BPM"
        return count == 1 ? "1 chunk, every \(every)" : "\(count) chunks, every \(every)"
    }

    /// What a gather will combine: one clip per pass of the batch (`count`; nil without a batch). A Concatenate
    /// joins them, `inputs` per pass, or just its inputs without a batch; the others gather them.
    static func gatherText(_ kind: NodeKind, _ count: Int?, inputs: Int = 1) -> String {
        let verb = kind == .concatenate ? "Joins" : "Gathers"
        guard let count else {
            guard kind == .concatenate else { return "\(verb) every file of the batch before it" }
            return switch inputs {
            case 0: "Joins its inputs end to end"
            case 1: "Joins 1 input"
            default: "Joins \(inputs) inputs end to end"
            }
        }
        if kind == .concatenate, inputs > 1 {
            return count == 0 ? "Joins \(inputs) inputs of every file of the batch before it"
                : "Joins \(inputs) inputs × \(count) files = \(inputs * count) clips"
        }
        return switch count {
        case 0: "\(verb) every file of the batch before it"
        case 1: "\(verb) 1 clip"
        default: "\(verb) \(count) clips"
        }
    }

    /// Where a For Each Splitter sends the first few passes of its batch ("1 → out 1 · 2 → out 2 · …").
    nonisolated static func splitterText(_ values: [ParameterID: ParameterValue], passes: Int) -> String {
        if values["mode"] == .choice("broadcast") { return "Every file goes down every output." }
        guard passes > 0 else { return "Sends each file of the batch before it down one output." }
        let shown = (0..<min(passes, 4)).map { index in
            let outputs = BatchRun.splitterOutputs(values, pass: index, passes: passes).sorted()
            return "\(index + 1) → \(outputs.map { $0.replacingOccurrences(of: "out", with: "out ") }.joined(separator: ", "))"
        }
        return (shown + (passes > 4 ? ["…"] : [])).joined(separator: " · ")
    }

    /// Where a Merry-Go-Round deals the first six passes of its batch ("1 → out 1 · 2 → out 2 · …").
    nonisolated static func dealText(_ values: [ParameterID: ParameterValue], passes: Int) -> String {
        guard passes > 0 else { return "Deals each file of the batch before it to one output in turn." }
        let shown = BatchRun.merryGoRoundDeal(values, passes: min(passes, 6)).enumerated().map { "\($0.offset + 1) → out \($0.element + 1)" }
        return (shown + (passes > 6 ? ["…"] : [])).joined(separator: " · ")
    }

    /// A Spectral Sorter's three ranges, in its Measure's units ("Low < 150 Hz · Mid 150–3000 Hz · High ≥ 3000 Hz").
    nonisolated static func sorterText(_ values: [ParameterID: ParameterValue]) -> String {
        let measure = SorterRoute.measureName(values)
        let unit = ["loudness": "dBFS", "decay": "ms"][measure] ?? "Hz"
        func number(_ suffix: String) -> String {
            let value = values[ParameterID("\(measure)\(suffix)")]?.numberValue ?? 0
            return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        }
        let low = number("Low"), high = number("High")
        return "Low < \(low) \(unit) · Mid \(low)–\(high) \(unit) · High ≥ \(high) \(unit)"
    }

    /// What a Combinatorial Matrix makes: one file per combination of the batches on A, B and C.
    static func combinationsText(_ counts: [Int]) -> String {
        guard !counts.isEmpty else { return "Layers A, B and C. Feed batches in for every combination." }
        let total = counts.reduce(1, *)
        return "\(counts.map(String.init).joined(separator: " × ")) = \(total) \(total == 1 ? "combination" : "combinations")"
    }

    /// A Large Audio Processor's count; nil while its file is still being sliced.
    static func sliceCountText(_ count: Int?) -> String {
        switch count {
        case nil: "Slicing…"
        case 0?: "No slices"
        case 1?: "1 slice"
        case let count?: "\(count) slices"
        }
    }
}

/// Page 2: tick parameters to spawn modulation pins, then the node's settings.
struct ModulationPage: View {
    let node: Node
    @Binding var project: ProjectFile
    let model: CanvasModel
    /// Last-bake summaries of what is wired into this node's inputs, for the modulation lanes.
    var inputSummaries: [PinID: NodeSummary] = [:]

    var body: some View {
        // Controls a setting has switched off (e.g. Rate on a Clock-synced LFO) are left out; their values stay.
        let shown = NodeCatalog.visibleParameters(of: node, in: project)
        let modulatable = shown.filter(\.isModulatable)
        let settings = shown.filter { $0.role == .setting }
        let values = NodeCatalog.resolvedParameters(of: node, in: project)
        VStack(alignment: .leading, spacing: 6) {
            if model.isEditingInside, ProjectFile.canPromote(node.kind) {
                PromoteSection(node: node, project: $project)
                Divider()
            }
            Text("Modulation").font(.caption).foregroundStyle(.secondary)
            if modulatable.isEmpty {
                Text("Nothing to modulate").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(modulatable, id: \.id) { parameter in
                Toggle(parameter.name, isOn: Binding(
                    get: { node.modulated.contains(parameter.id) },
                    set: { isOn in $project.edit { $0.setModulated(parameter.id, of: node.id, isOn) } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            if !settings.isEmpty {
                Divider()
                Text("Settings").font(.caption).foregroundStyle(.secondary)
                ForEach(settings, id: \.id) { parameter in
                    ParameterControl(
                        parameter: parameter, value: values[parameter.id], node: node.id, project: $project, model: model,
                        modulation: ControlModulation.of(parameter.id, on: node, inputs: inputSummaries)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inside a custom node: which of this card's controls also show on the custom node, as its own.
private struct PromoteSection: View {
    let node: Node
    @Binding var project: ProjectFile

    var body: some View {
        let parameters = NodeCatalog.definition(for: node.kind).parameters.filter { $0.role != .hidden }
        VStack(alignment: .leading, spacing: 6) {
            Text("On the Custom Node").font(.caption).foregroundStyle(.secondary)
            ForEach(parameters, id: \.id) { parameter in
                Toggle(parameter.name, isOn: Binding(
                    get: { node.promoted?.contains(parameter.id) == true },
                    set: { isOn in $project.edit { $0.setPromoted(parameter.id, of: node.id, isOn) } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
    }
}

/// What a modulated control shows under itself (see `ModulationLane`).
struct ControlModulation: Equatable {
    let trim: Double
    /// The modulation signal from the last bake; empty before one.
    let trace: [Float]

    /// The modulation of `parameter` on `node`, if it is ticked on Page 2.
    static func of(_ parameter: ParameterID, on node: Node, inputs: [PinID: NodeSummary]) -> ControlModulation? {
        guard node.modulated.contains(parameter) else { return nil }
        return ControlModulation(
            trim: node.modulationTrims[parameter] ?? 1,
            trace: inputs[NodeCatalog.modulationPinID(for: parameter)]?.detail ?? []
        )
    }
}

/// One parameter: slider (numbers, committed on release), menu (choices), or text field.
struct ParameterControl: View {
    let parameter: ParameterDefinition
    let value: ParameterValue?
    let node: NodeID
    @Binding var project: ProjectFile
    let model: CanvasModel
    /// Set while the parameter is modulated: a lane under the control shows where it goes.
    var modulation: ControlModulation? = nil

    var body: some View {
        switch parameter.kind {
        case let .number(range, _, unit):
            let mapping = SliderMapping(range: range, scale: parameter.modulationScale, taper: parameter.taper)
            // Whole-number settings show and snap to whole numbers (the renderer rounds them too).
            let number = parameter.isInteger ? (value?.numberValue ?? range.lowerBound).rounded() : value?.numberValue ?? range.lowerBound
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(parameter.name)
                    Spacer()
                    TypedValue(display: ParameterFormat.string(number, unit: unit), value: number, id: parameter.id) { typed in
                        let clamped = min(max(parameter.isInteger ? typed.rounded() : typed, range.lowerBound), range.upperBound)
                        $project.edit { $0.setParameter(parameter.id, of: node, to: .number(clamped)) }
                    }
                }
                .font(.caption)
                Slider(
                    value: Binding(
                        get: { mapping.position(for: number) },
                        set: {
                            let raw = mapping.value(at: $0)
                            model.preview(parameter.id, of: node, value: .number(parameter.isInteger ? raw.rounded() : raw))
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing { $project.edit { model.commitParameter(in: &$0) } }
                    }
                )
                .controlSize(.mini)
                .accessibilityLabel(parameter.name)
                .accessibilityValue(ParameterFormat.string(number, unit: unit))
                if let modulation {
                    ModulationLane(
                        range: ModulationRange(parameter: parameter, value: value, trim: modulation.trim),
                        trace: modulation.trace, mapping: mapping
                    )
                }
            }
        case let .choice(options, defaultValue):
            let current: String = if case .choice(let choice)? = value { choice } else { defaultValue }
            Picker(parameter.name, selection: Binding(
                get: { current },
                set: { choice in $project.edit { $0.setParameter(parameter.id, of: node, to: .choice(choice)) } }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(ParameterFormat.title(forChoice: option, of: parameter.id)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.caption)
            if let modulation {
                ModulationLane(
                    range: ModulationRange(parameter: parameter, value: value, trim: modulation.trim),
                    trace: modulation.trace, mapping: nil
                )
            }
        case let .text(defaultValue):
            let current: String = if case .text(let text)? = value { text } else { defaultValue }
            TextSetting(name: parameter.name, value: current) { text in
                $project.edit { $0.setParameter(parameter.id, of: node, to: .text(text)) }
            }
        }
    }
}

/// A text setting that writes as you type. Clicking a toolbar button (e.g. Bake) doesn't take
/// focus on macOS, so a field that waited for Return or focus loss would bake the old text.
struct TextSetting: View {
    let name: String
    let value: String
    let commit: @MainActor (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption)
            TextField(name, text: Binding(get: { value }, set: { commit($0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// A small knob for a modulation trim (−1…+1). Drag up or down; writes once on release.
struct TrimKnob: View {
    let value: Double
    let onChange: (Double) -> Void
    let onCommit: () -> Void
    @State private var startValue: Double?

    var body: some View {
        ZStack {
            Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1.5)
            KnobArc(value: value).stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 16, height: 16)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = startValue ?? value
                    if startValue == nil { startValue = value }
                    onChange(min(max(start - drag.translation.height / 100, -1), 1))
                }
                .onEnded { _ in
                    startValue = nil
                    onCommit()
                }
        )
        .help("Trim")
        .accessibilityLabel("Trim")
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : direction == .decrement ? -0.1 : 0
            guard step != 0 else { return }
            onChange(min(max(value + step, -1), 1))
            onCommit()
        }
    }
}

/// Arc from 12 o'clock: clockwise for positive trim, anticlockwise for negative.
struct KnobArc: Shape {
    let value: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 - 3,
            startAngle: .degrees(-90), endAngle: .degrees(-90 + value * 135), clockwise: value < 0
        )
        return path
    }
}

/// Problems the last bake found on this node.
struct IssueList: View {
    let issues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .accessibilityIdentifier("issues")
    }
}

/// A tick at every slice start, over a Large Audio Processor's waveform.
struct SliceMarks: View {
    let marks: [Double]

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for mark in marks {
                let x = (size.width * mark).rounded() + 0.5
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(.accentColor.opacity(0.8)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A Corpus Scatter's first seconds: a dot where each grain starts, higher for a higher pitch, brighter
/// toward the centre of the pan. From the settings alone, so it shows before a bake.
struct ScatterOnsets: View {
    static let seconds = 4.0

    let grains: [ScatterSchedule.Grain]

    /// The schedule's first `seconds`, with starts in milliseconds.
    static func grains(_ values: [ParameterID: ParameterValue], clips: Int) -> [ScatterSchedule.Grain] {
        Array(ScatterSchedule.grains(clips: max(clips, 1), parameters: values, sampleRate: 1_000, seconds: seconds).prefix(2_000))
    }

    var body: some View {
        Canvas { context, size in
            let limit = grains.map { abs($0.semitones) }.max() ?? 0
            for grain in grains {
                let x = size.width * Double(grain.start) / (Self.seconds * 1_000)
                let lift = limit > 0 ? grain.semitones / limit : 0
                let y = size.height * (0.5 - 0.4 * lift)
                let dot = CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)
                context.fill(Path(ellipseIn: dot), with: .color(.accentColor.opacity(1 - 0.5 * abs(grain.pan))))
            }
        }
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 4))
        .allowsHitTesting(false)
        .accessibilityLabel("\(grains.count) grains in the first \(Int(Self.seconds)) seconds")
    }
}

/// A Batch Audio node's folder: its name, how many files it plays, and a button to choose another.
struct BatchFolderRow: View {
    let node: NodeID
    let folderName: String?
    let fileCount: Int?
    let choose: ((NodeID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(folderName ?? "No folder")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(folderName == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") { choose?(node) }
                    .controlSize(.small)
                    .disabled(choose == nil)
                    .help("The folder whose audio files this node plays, one per bake")
            }
            if folderName != nil {
                Text(Self.countText(fileCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(folderName.map { "\($0), \(Self.countText(fileCount))" } ?? "No folder")
    }

    static func countText(_ count: Int?) -> String {
        switch count {
        case nil: "Folder not found"
        case 0?: "No audio files"
        case 1?: "1 file"
        case let count?: "\(count) files"
        }
    }
}

/// Where a Bake node writes; click to choose its own folder.
struct BakeFolderRow: View {
    let node: NodeID
    let folderName: String?
    let actions: NodeActions

    var body: some View {
        Button { actions.chooseFolder?(node) } label: {
            Label(folderName ?? "Choose Folder…", systemImage: "folder")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .disabled(actions.chooseFolder == nil)
        .help("Where this node writes. Without one, it uses the default folder from the toolbar.")
        .accessibilityIdentifier("bakeFolder")
    }
}

struct AudioFileRow: View {
    let node: NodeID
    let fileName: String?
    /// The file can't be found or read: Locate… points it at the file's new place, for every node
    /// playing it; Choose… gives only this node a different file.
    var isMissing = false
    let choose: ((NodeID) -> Void)?
    var locate: ((NodeID) -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "waveform")
                .foregroundStyle(isMissing ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            Text(fileName ?? "No file")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(isMissing)
                .foregroundStyle(fileName == nil || isMissing ? .secondary : .primary)
            Spacer()
            if isMissing, let locate {
                Button("Locate…") { locate(node) }
                    .controlSize(.small)
                    .help("Find this file where it is now; every node playing it follows")
            } else {
                Button("Choose…") { choose?(node) }
                    .controlSize(.small)
                    .disabled(choose == nil)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isMissing ? "Missing file \(fileName ?? "")" : fileName ?? "No file")
    }
}

/// How long this node's audio will be (not how long the bake takes); amber when it's very long, or
/// when a modulation source is so short that rates in Hz and envelope times hardly play out.
struct OutputLengthRow: View {
    let seconds: Double
    var isModulationSource = false

    enum Warning: Equatable {
        case long
        case shortModulation
    }

    static func warning(seconds: Double, isModulationSource: Bool) -> Warning? {
        if seconds >= 600 { return .long }
        if isModulationSource && seconds < 0.1 { return .shortModulation }
        return nil
    }

    var body: some View {
        let warning = Self.warning(seconds: seconds, isModulationSource: isModulationSource)
        let text = warning == .shortModulation
            ? "Runs only \(ParameterFormat.duration(seconds))" : "Length \(ParameterFormat.duration(seconds))"
        Label(text, systemImage: warning == nil ? "waveform" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(warning == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .help(help(for: warning))
    }

    private func help(for warning: Warning?) -> String {
        switch warning {
        case .long: "Length of the audio this node makes. Very long audio means a big file and a lot of memory while baking."
        case .shortModulation:
            "This modulation lasts only as long as what it feeds. In \(ParameterFormat.duration(seconds)) a rate in Hz or an envelope time hardly plays out. Use LFO Sync › Over Length, or make the signal longer (more Cycles on a Single Cycle)."
        case nil: "Length of the audio this node makes"
        }
    }
}

/// A number's value label, which is also a borderless text field: click it and type an exact value
/// ("140.5", "500 ms", "2k"). Return, or clicking away, sets it; Escape puts the shown value back.
/// The field always holds its own text and shows the current value whenever it isn't being typed in:
/// the canvas is focusable itself, so focus tracking inside a card can't be relied on.
struct TypedValue: View {
    let display: String
    let value: Double
    let id: ParameterID
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 90)
            .focused($isFocused)
            .onAppear { text = display }
            .onChange(of: display) { _, shown in text = shown }
            .onSubmit(set)
            .onChange(of: isFocused) { _, focused in
                if !focused { set() }
            }
            .onExitCommand { text = display }
            .help("Click to type a value")
            .accessibilityIdentifier("value.\(id)")
    }

    private func set() {
        guard text != display, let typed = Self.number(in: text) else {
            text = display
            return
        }
        commit(typed)
        text = display
    }

    /// The first number in `text`, either decimal separator; a "k" after it means thousands.
    static func number(in text: String) -> Double? {
        let lowered = text.lowercased().replacingOccurrences(of: ",", with: ".")
        guard let match = lowered.firstMatch(of: /[-+]?(\d+\.?\d*|\.\d+)/), let number = Double(match.output.0) else { return nil }
        let rest = lowered[match.range.upperBound...]
        let value = rest.trimmingCharacters(in: .whitespaces).hasPrefix("k") ? number * 1_000 : number
        return value.isFinite ? value : nil
    }
}

import BakeGraph
import SwiftUI

/// What cards can ask the app to do. Everything is optional, so previews and tests can pass `NodeActions()`.
/// Cards never present file pickers themselves: the window owns one, because SwiftUI on macOS
/// ignores a `fileImporter` nested inside another (the toolbar's), so card pickers never opened.
public struct NodeActions {
    /// An audio file dropped on an Audio node.
    public var importAudio: ((NodeID, URL) -> Void)?
    /// Ask the app to pick an audio file for an Audio node.
    public var chooseAudio: ((NodeID) -> Void)?
    /// Ask the app to pick a folder for a Bake node.
    public var chooseFolder: ((NodeID) -> Void)?
    public var bake: ((NodeID) -> Void)?
    /// Render a Preview node's path and play it.
    public var preview: ((NodeID) -> Void)?
    public var stopPreview: (() -> Void)?
    /// A baked WAV carrying its patch was dropped on the empty canvas: open the patch.
    public var openWorkflow: ((BakedWorkflow) -> Void)?
    /// Any other audio file dropped on the empty canvas: a new Audio node for it, at this point.
    public var addAudio: ((URL, CanvasPoint) -> Void)?
    /// Open a custom node to edit its definition. The workspace sets this itself.
    public var editInside: ((NodeID) -> Void)?
    /// Custom nodes (spec §12, Phase C): the library's files, listed in Add Node › Custom; saving or
    /// exporting a document's definition; picking a `.bakenode` to add at a point; one dropped there.
    public var customNodeLibrary: [CustomNodeFile] = []
    /// Audio files that can't be found or read, and asking the app to find one again (Locate…).
    public var missingAssets: Set<AssetID> = []
    public var locateAudio: ((NodeID) -> Void)?
    public var saveCustomNodeToLibrary: ((UUID) -> Void)?
    public var exportCustomNode: ((UUID) -> Void)?
    public var importCustomNode: ((CanvasPoint) -> Void)?
    public var addCustomNodeFile: ((URL, CanvasPoint) -> Void)?
    /// Batch Audio: each node's files as its folder lists them now; asking the app to pick a folder;
    /// a folder dropped on the card.
    public var batchFiles: [NodeID: [BatchFile]] = [:]
    /// Large Audio Processor: where its slices start, as fractions of its file.
    public var sliceMarks: [NodeID: [Double]] = [:]
    /// The words Random Words names come from, so a Batch Bake card can show its first name.
    public var wordLists: WordLists = .builtIn
    public var chooseSourceFolder: ((NodeID) -> Void)?
    public var useSourceFolder: ((NodeID, URL) -> Void)?
    public var isBaking: Bool

    public init(
        importAudio: ((NodeID, URL) -> Void)? = nil, chooseAudio: ((NodeID) -> Void)? = nil,
        chooseFolder: ((NodeID) -> Void)? = nil, bake: ((NodeID) -> Void)? = nil,
        preview: ((NodeID) -> Void)? = nil, stopPreview: (() -> Void)? = nil,
        openWorkflow: ((BakedWorkflow) -> Void)? = nil, addAudio: ((URL, CanvasPoint) -> Void)? = nil,
        isBaking: Bool = false
    ) {
        self.importAudio = importAudio
        self.chooseAudio = chooseAudio
        self.chooseFolder = chooseFolder
        self.bake = bake
        self.preview = preview
        self.stopPreview = stopPreview
        self.openWorkflow = openWorkflow
        self.addAudio = addAudio
        self.isBaking = isBaking
    }
}

/// The node canvas: dot grid, wires, and node cards over a pannable, zoomable world.
public struct WorkspaceView: View {
    @Binding var project: ProjectFile
    @State private var model = CanvasModel()
    @State private var panStart: CGPoint?
    @State private var lastMagnification: CGFloat = 1
    /// The custom node definition being edited (Edit Inside), or nil for the patch itself.
    @State private var editing: UUID?
    @FocusState private var isFocused: Bool
    /// Where the node search is open, if it is.
    @State private var search: SearchSpot?
    let issues: GraphIssues
    /// Source metadata, so cards can show each node's output length before a bake.
    let assetInfo: [AssetID: AssetInfo]
    /// Waveforms to show: Audio nodes' sources and Preview nodes' last renders.
    let waveforms: [NodeID: WaveformPeaks]
    /// What each node produced in the last bake, and which of those no longer match the graph.
    let summaries: [NodeID: NodeSummary]
    /// The same per output pin, for wires from a node's second output (and that node's own card).
    let outputSummaries: [PinRef: NodeSummary]
    let staleSummaries: Set<NodeID>
    let playingPreview: NodeID?
    let actions: NodeActions

    public init(
        project: Binding<ProjectFile>, issues: GraphIssues = GraphIssues(),
        assetInfo: [AssetID: AssetInfo] = [:], waveforms: [NodeID: WaveformPeaks] = [:],
        summaries: [NodeID: NodeSummary] = [:], outputSummaries: [PinRef: NodeSummary] = [:], staleSummaries: Set<NodeID> = [],
        playingPreview: NodeID? = nil, actions: NodeActions = NodeActions()
    ) {
        _project = project
        self.issues = issues
        self.assetInfo = assetInfo
        self.waveforms = waveforms
        self.summaries = summaries
        self.outputSummaries = outputSummaries
        self.staleSummaries = staleSummaries
        self.playingPreview = playingPreview
        self.actions = actions
    }

    /// What the canvas shows and edits: the patch, or the definition being edited inside. Edits
    /// inside write straight back into the definition, so they're one undo step like any other.
    private var canvas: Binding<ProjectFile> {
        guard let editing, let inside = project.inside(editing) else { return $project }
        return Binding(
            get: { project.inside(editing) ?? inside },
            set: { project.storeInside($0, into: editing) }
        )
    }

    /// The patch's problems, or inside a custom node, the ones on its own cards.
    private var shownIssues: GraphIssues {
        guard let editing else { return issues }
        return issues.inside[editing] ?? GraphIssues()
    }

    private var editingName: String? {
        editing.flatMap { id in project.customNodes.first { $0.id == id }?.name }
    }

    private var cardActions: NodeActions {
        var actions = actions
        actions.editInside = { id in enterCustomNode(id) }
        return actions
    }

    private func enterCustomNode(_ id: NodeID) {
        guard editing == nil, let definition = project.node(id)?.customDefinition,
              project.customNodes.contains(where: { $0.id == definition }) else { return }
        model.clearSelection()
        model.isEditingInside = true
        editing = definition
    }

    /// The kinds Add Node offers here: inside a custom node, no In & Out or Batch (the patch's Audio,
    /// Bake, Preview and batch nodes stay outside).
    private var offeredCategories: [NodeCategory] {
        NodeCategory.allCases.filter { $0.isInAddMenu && (editing == nil || ($0 != .inOut && $0 != .batch)) }
    }

    /// Opens the node search over the middle of the view; the card goes where menu adds go.
    private func openSearch() {
        search = SearchSpot(point: CGPoint(x: model.viewSize.width / 2, y: model.viewSize.height / 3), position: nil)
    }

    private func add(_ item: NodeSearchItem, at position: CanvasPoint?) {
        switch item {
        case .kind(let kind): canvas.edit { model.addNode(kind, at: position, in: &$0) }
        case .custom(let definition, _): $project.edit { model.addCustomNode(definition, at: position, in: &$0) }
        }
        search = nil
    }

    private func addButtons(_ kinds: [NodeKind]) -> some View {
        ForEach(kinds, id: \.self) { kind in
            Button(kind.title) { canvas.edit { model.addNode(kind, in: &$0) } }
        }
    }

    private func leaveCustomNode() {
        model.clearSelection()
        model.isEditingInside = false
        editing = nil
    }

    /// The chunk count of each Photo Booth with an unwired Trigger, from its input's length.
    nonisolated static func boothCounts(in project: ProjectFile, lengths: [NodeID: SignalShape]) -> [NodeID: Int] {
        var counts: [NodeID: Int] = [:]
        let triggered = Set(project.edges.filter { $0.to.pin == "trigger" }.map(\.to.node))
        for node in project.nodes where node.kind == .photoBooth && !triggered.contains(node.id) {
            guard let frames = lengths[node.id]?.frames else { continue }
            counts[node.id] = PhotoBoothChunks.gridCount(
                frames: frames, parameters: NodeCatalog.resolvedParameters(of: node), sampleRate: project.settings.sampleRate
            )
        }
        return counts
    }

    public var body: some View {
        let current = canvas.wrappedValue
        let shown = model.displayed(current)
        // Lengths before a bake: a Batch Audio as long as its first file (`BakeSession.assetInfo` has it).
        let unplanned = BatchRun(project: shown, files: actions.batchFiles, wordLists: actions.wordLists)
        let lengths = GraphCompiler.previewShapes(unplanned.pass(0), assets: assetInfo)
        // A Concatenate without a batch before it is an ordinary node, with a length like any other.
        let activeGathers = Set(unplanned.gathers)
        // A Photo Booth on its own grid knows its chunks before a bake; one on a wired trigger doesn't.
        let boothCounts = Self.boothCounts(in: shown, lengths: lengths)
        let batch = boothCounts.isEmpty ? unplanned : BatchRun(
            project: shown, files: actions.batchFiles.merging(boothCounts.mapValues { count in
                (0..<count).map { BatchFile(path: "#\($0 + 1)") }
            }) { $1 }, wordLists: actions.wordLists
        )
        ZStack(alignment: .topLeading) {
            DotGrid(viewport: model.viewport)
                .accessibilityHidden(true)
                .contentShape(Rectangle())
                .gesture(panGesture)
                .onTapGesture(coordinateSpace: .named(CanvasSpace.name)) { location in
                    isFocused = true
                    model.click(atView: location, in: current)
                }
                // Double-click the empty canvas to search for a node and add it there.
                .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named(CanvasSpace.name)).onEnded { tap in
                    search = SearchSpot(point: tap.location, position: model.cardPosition(atView: tap.location))
                })
                // Drops on the empty canvas; a drop on a card goes to the card.
                .dropDestination(for: URL.self) { urls, location in
                    guard let url = urls.first else { return false }
                    return CanvasDrop.handle(url, atView: location, viewport: model.viewport, actions: actions)
                }
            ScrollWheelCatcher { delta, location, zoom in
                if zoom {
                    model.viewport.zoom(by: exp(delta.height * 0.01), around: location)
                } else {
                    model.viewport.pan(by: delta)
                }
            }
            FeedbackGroupLayer(project: shown, model: model)
            // Wires are read through their pins ("connected from LFO"), so the drawing stays out of VoiceOver.
            WireLayer(project: shown, model: model)
                .accessibilityHidden(true)
            ForEach(shown.nodes) { node in
                let origin = model.viewport.toView(CGPoint(node.position))
                NodeCardView(
                    node: node, isSelected: model.isSelected(node.id),
                    issues: shownIssues.nodes[node.id] ?? [],
                    issuePins: Set(shownIssues.pins.filter { $0.node == node.id }.map(\.pin)),
                    fileName: node.kind == .batchAudio
                        ? node.sourceFolder.map { URL(filePath: $0.lastKnownPath).lastPathComponent }
                        : shown.audioFileName(for: node.id),
                    isFileMissing: node.assetID.map(actions.missingAssets.contains) ?? false,
                    // A gather's length is known only after the passes.
                    outputSeconds: activeGathers.contains(node.id) ? nil : lengths[node.id].map { Double($0.frames) / shown.settings.sampleRate },
                    folderName: node.kind == .print || node.kind == .batchBake ? Self.folderName(for: node, in: shown) : nil,
                    batchFileCount: node.kind == .photoBooth ? boothCounts[node.id]
                        : node.kind.isBatchSource ? actions.batchFiles[node.id]?.count
                        : batch.waitsForTriggers(node.id) ? nil
                        : node.kind == .batchBake || activeGathers.contains(node.id) || node.kind.isRouter ? batch.passCount : nil,
                    combinationCounts: node.id == batch.matrix && batch.passCount > 0 ? batch.axisCounts : [],
                    sliceMarks: actions.sliceMarks[node.id] ?? [],
                    firstFileName: node.kind == .batchBake && batch.passCount > 0
                        ? "\(batch.fileName(of: node.id, pass: 0)).wav" : nil,
                    isBaking: actions.isBaking,
                    waveform: waveforms[node.id], isPlaying: playingPreview == node.id,
                    summary: summaries[node.id], isSummaryStale: staleSummaries.contains(node.id),
                    inputSummaries: CardInputs.summaries(feeding: node, in: shown, from: summaries, outputs: outputSummaries),
                    outputSummaries: CardInputs.outputs(of: node, from: outputSummaries),
                    definition: shown.definition(of: node),
                    project: canvas, model: model, actions: cardActions
                )
                    .equatable()
                    .scaleEffect(model.viewport.scale, anchor: .topLeading)
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .overlay(alignment: .top) {
            if let editing, let editingName {
                InsideBar(
                    name: Binding(
                        get: { editingName },
                        set: { name in $project.edit { $0.renameCustomNode(editing, to: name) } }
                    ),
                    leave: leaveCustomNode,
                    saveToLibrary: actions.saveCustomNodeToLibrary.map { save in { save(editing) } },
                    export: actions.exportCustomNode.map { export in { export(editing) } }
                )
            }
        }
        .popover(item: $search, attachmentAnchor: .rect(.rect(CGRect(origin: search?.point ?? .zero, size: .zero)))) { spot in
            NodeSearchView(
                kinds: offeredCategories.flatMap(\.kinds),
                customNodes: editing == nil ? project.customNodes : [],
                add: { add($0, at: spot.position) }
            )
        }
        .coordinateSpace(.named(CanvasSpace.name))
        .clipped()
        .simultaneousGesture(zoomGesture)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.viewSize = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onDeleteCommand { canvas.edit { model.deleteSelection(in: &$0) } }
        // Keyboard: Tab between cards, arrows to nudge them, Space to flip their page.
        // Selecting a card (a click on its header) gives the canvas the keyboard, for the keys below.
        .onChange(of: model.selection) { if !model.selection.isEmpty { isFocused = true } }
        // Only while the canvas itself has focus: typing in a card's field keeps Tab and Space.
        .onKeyPress(.tab) {
            guard isFocused else { return .ignored }
            model.selectNext(in: current, backwards: NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard isFocused, !model.selection.isEmpty else { return .ignored }
            let dx: Double = press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 : 0
            let dy: Double = press.key == .upArrow ? -1 : press.key == .downArrow ? 1 : 0
            canvas.edit { model.nudgeSelection(dx: dx, dy: dy, in: &$0) }
            return .handled
        }
        .onKeyPress(.space) {
            guard isFocused, !model.selection.isEmpty else { return .ignored }
            model.flipSelection()
            return .handled
        }
        .toolbar {
            ToolbarItem {
                Menu("Add Node", systemImage: "plus") {
                    Button("Search…", systemImage: "magnifyingglass", action: openSearch)
                    Divider()
                    // Effects holds its subgroups and Spectral; the other groups list their nodes.
                    ForEach(offeredCategories.filter { $0.parent == nil }, id: \.self) { category in
                        Menu(category.title) {
                            ForEach(category.subgroups, id: \.self) { subgroup in
                                Menu(subgroup.title) { addButtons(subgroup.kinds) }
                            }
                            ForEach(category.children, id: \.self) { child in
                                Menu(child.title) { addButtons(child.kinds) }
                            }
                            if category.subgroups.isEmpty { addButtons(category.kinds) }
                        }
                    }
                    // The document's custom nodes, then the library's; not inside one (no nesting in v1).
                    if editing == nil {
                        Menu(NodeCategory.custom.title) {
                            ForEach(project.customNodes) { definition in
                                Button(definition.name) { $project.edit { model.addCustomNode(definition.id, in: &$0) } }
                            }
                            let library = actions.customNodeLibrary.filter { file in !project.customNodes.contains(file.definition) }
                            if !library.isEmpty {
                                Section("Library") {
                                    ForEach(library, id: \.definition.id) { file in
                                        Button(file.definition.name) { $project.edit { model.addCustomNode(from: file, in: &$0) } }
                                    }
                                }
                            }
                            Divider()
                            Button("Import Custom Node…") { actions.importCustomNode?(model.centrePosition) }
                                .disabled(actions.importCustomNode == nil)
                        }
                    }
                }
                .accessibilityIdentifier("addNode")
            }
        }
        #if DEBUG
        .task { await runBenchmarkIfRequested() }
        #endif
        .focusedSceneValue(\.canvasActions, CanvasActions(
            zoomIn: { model.zoom(by: 1.25) },
            zoomOut: { model.zoom(by: 0.8) },
            actualSize: { model.actualSize() },
            insertStressGraph: { $project.edit { $0 = StressGraph.project() } },
            group: { $project.edit { model.groupSelection(in: &$0) } },
            ungroup: { $project.edit { model.ungroupSelection(in: &$0) } },
            canGroup: editing == nil && model.canGroupSelection(in: project),
            canUngroup: editing == nil && model.canUngroupSelection(in: project),
            feedbackGroup: { $project.edit { model.makeFeedbackGroup(in: &$0) } },
            canFeedbackGroup: editing == nil && model.canMakeFeedbackGroup(in: project),
            searchNodes: openSearch
        ))
    }

    #if DEBUG
    /// Launched with `-bakeBenchmark`: loads the 100-node stress graph and sweeps pan and zoom for
    /// 15 s, so Instruments can measure the canvas without UI-test or accessibility clients
    /// (which walk every card's accessibility tree and dominate the main thread).
    private func runBenchmarkIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-bakeBenchmark") else { return }
        $project.edit { $0 = StressGraph.project() }
        let start = Date()
        while Date().timeIntervalSince(start) < 15, !Task.isCancelled {
            let t = Date().timeIntervalSince(start)
            model.viewport = Viewport(
                offset: CGPoint(x: 200 + 500 * cos(t * 0.9), y: 100 + 500 * sin(t * 0.6)),
                scale: 0.6 + 0.4 * sin(t * 0.7)
            )
            try? await Task.sleep(for: .milliseconds(8))
        }
    }
    #endif

    /// A Bake node's own folder, else the project's default ("Default: …"), else nil.
    nonisolated static func folderName(for node: Node, in project: ProjectFile) -> String? {
        if let own = node.outputFolder {
            return URL(filePath: own.lastKnownPath).lastPathComponent
        }
        return project.settings.printFolder.map { "Default: " + URL(filePath: $0.lastKnownPath).lastPathComponent }
    }

    /// Dragging empty canvas pans.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = panStart ?? model.viewport.offset
                panStart = start
                model.viewport.offset = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    /// Trackpad pinch zooms around the pinch point.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                model.viewport.zoom(by: value.magnification / lastMagnification, around: value.startLocation)
                lastMagnification = value.magnification
            }
            .onEnded { _ in lastMagnification = 1 }
    }
}

/// Shown while editing inside a custom node: where you are, its name (editable), and the way back.
private struct InsideBar: View {
    @Binding var name: String
    let leave: () -> Void
    var saveToLibrary: (() -> Void)?
    var export: (() -> Void)?
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            Button("Patch", systemImage: "chevron.left", action: leave)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back to the patch (Esc)")
            Text("›").foregroundStyle(.secondary)
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.headline)
                .fixedSize()
                .onSubmit { name = draft }
                .onAppear { draft = name }
                .onChange(of: name) { draft = name }
                .onDisappear { if draft != name { name = draft } }
                .help("The custom node's name")
            Text("Changes apply to every \(name) in the patch.").font(.caption).foregroundStyle(.secondary)
            if let saveToLibrary {
                Button("Save to Library", systemImage: "books.vertical", action: saveToLibrary)
                    .help("Keep this custom node in the library, for every document")
            }
            if let export {
                Button("Export…", systemImage: "square.and.arrow.up", action: export)
                    .help("Save this custom node as a .bakenode file to share")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
    }
}

/// A translucent box behind each feedback loop's cards: the Feedback node, the chain it feeds and
/// the node wired back into its Return (spec §11). Card heights aren't tracked, so the box allows
/// for a typical card body below each card's pins.
struct FeedbackGroupLayer: View {
    let project: ProjectFile
    let model: CanvasModel

    private static let padding: CGFloat = 16
    private static let bodyAllowance: CGFloat = 180

    var body: some View {
        let viewport = model.viewport
        Canvas { context, _ in
            let nodes = Dictionary(project.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for loop in project.feedbackLoops() {
                let frames = loop.members.compactMap { nodes[$0] }.map { node in
                    CGRect(
                        x: node.position.x, y: node.position.y, width: NodeLayout.width,
                        height: NodeLayout.headerHeight + CGFloat(NodeLayout.portRows(of: node, in: project)) * NodeLayout.portRowHeight
                            + Self.bodyAllowance
                    )
                }
                guard let first = frames.first else { continue }
                let world = frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -Self.padding, dy: -Self.padding)
                let topLeft = viewport.toView(world.origin)
                let bottomRight = viewport.toView(CGPoint(x: world.maxX, y: world.maxY))
                let rect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
                let shape = Path(roundedRect: rect, cornerRadius: 14 * viewport.scale)
                context.fill(shape, with: .color(SignalType.audio.color.opacity(0.06)))
                context.stroke(shape, with: .color(SignalType.audio.color.opacity(0.35)),
                               style: StrokeStyle(lineWidth: max(viewport.scale, 0.5), dash: [6, 4]))
                context.draw(
                    Text("Feedback loop").font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: rect.minX + 10, y: rect.minY + 8), anchor: .topLeading
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Every wire in one `Canvas`, plus the wire being dragged. Drawing only — hit tests are geometric.
struct WireLayer: View {
    let project: ProjectFile
    let model: CanvasModel

    var body: some View {
        let viewport = model.viewport
        let width = max(2 * viewport.scale, 1)
        Canvas { context, _ in
            for edge in project.edges {
                guard let curve = WireCurve(edge: edge, in: project) else { continue }
                let color = (project.pin(edge.from)?.signal ?? .audio).color
                let selected = edge == model.selectedEdge
                context.stroke(Self.path(curve, viewport), with: .color(selected ? .accentColor : color),
                               style: StrokeStyle(lineWidth: selected ? width * 1.75 : width, lineCap: .round))
            }
            if let wire = model.pendingWire, let curve = model.pendingCurve(in: project) {
                let color = (project.pin(wire.anchor)?.signal ?? .audio).color
                let dash: [CGFloat] = wire.target == nil ? [6, 4] : []
                context.stroke(Self.path(curve, viewport), with: .color(color),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            }
        }
        .allowsHitTesting(false)
    }

    static func path(_ curve: WireCurve, _ viewport: Viewport) -> Path {
        var path = Path()
        path.move(to: viewport.toView(curve.start))
        path.addCurve(to: viewport.toView(curve.end), control1: viewport.toView(curve.control1), control2: viewport.toView(curve.control2))
        return path
    }
}

/// Background dots every 24 world points, thinned out when zoomed far out.
struct DotGrid: View {
    let viewport: Viewport

    var body: some View {
        Canvas { context, size in
            var spacing = 24 * viewport.scale
            while spacing < 12 { spacing *= 2 }
            let startX = viewport.offset.x.truncatingRemainder(dividingBy: spacing)
            let startY = viewport.offset.y.truncatingRemainder(dividingBy: spacing)
            var dots = Path()
            var y = startY
            while y < size.height {
                var x = startX
                while x < size.width {
                    dots.addRect(CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(.secondary.opacity(0.35)))
        }
    }
}

/// What a file dropped on the empty canvas does: a baked WAV that carries its patch opens it (in a
/// new window, so nothing here is replaced); any other audio file becomes an Audio node where it
/// landed.
enum CanvasDrop {
    @MainActor
    static func handle(_ url: URL, atView location: CGPoint, viewport: Viewport, actions: NodeActions) -> Bool {
        if url.pathExtension == CustomNodeFile.fileExtension, let add = actions.addCustomNodeFile {
            let world = viewport.toWorld(location)
            add(url, CanvasPoint(x: Double(world.x - NodeLayout.width / 2).rounded(), y: Double(world.y - 20).rounded()))
            return true
        }
        if let workflow = BakedWorkflow.read(fromWAV: url), let open = actions.openWorkflow {
            open(workflow)
            return true
        }
        guard let addAudio = actions.addAudio else { return false }
        let world = viewport.toWorld(location)
        // The card's top-left corner a little up and left of the pointer, so the card lands under it.
        addAudio(url, CanvasPoint(x: Double(world.x - 40).rounded(), y: Double(world.y - 20).rounded()))
        return true
    }
}

/// Where the node search popover points, and where the picked card goes (nil: where menu adds go).
private struct SearchSpot: Identifiable {
    let id = UUID()
    let point: CGPoint
    let position: CanvasPoint?
}

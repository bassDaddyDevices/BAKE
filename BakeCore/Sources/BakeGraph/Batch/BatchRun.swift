import CryptoKit
import Foundation

/// One file a Batch Audio node plays.
public struct BatchFile: Hashable, Sendable {
    public var path: String
    public var bookmark: Data?

    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }

    /// The file's name without its extension, for `{source}`.
    public var name: String {
        URL(filePath: path).deletingPathExtension().lastPathComponent
    }
}

/// A batch bake: the patch rendered once per pass. In each pass every batch source (a Batch Audio's
/// folder, a Large Audio Processor's slices) plays its next file (a shorter list starts over) and every
/// Batch Bake writes that pass's file name, so the compiler and the engine only ever see an ordinary patch.
/// A gather (Concatenate) is captured in every pass and joined after them; what follows it renders once
/// (`afterPass`). With a Combinatorial Matrix, the batch sources on its inputs A, B and C are axes and
/// the passes are every combination of them instead (`axes`).
public struct BatchRun: Sendable {
    public let project: ProjectFile
    /// Each batch source's files, in the order it plays them.
    public let files: [NodeID: [BatchFile]]
    /// Random Words names, for each Batch Bake set to them, one per pass.
    private var randomNames: [NodeID: [String]]
    /// The Combinatorial Matrix the passes combine for (the first one an output depends on), if any.
    public let matrix: NodeID?
    /// The matrix's inputs A, B and C: the batch sources feeding each. Empty without a matrix.
    public let axes: [[NodeID]]

    /// For each Batch Bake behind a For Each Splitter, its number in each pass: how many files it wrote before.
    private var ordinals: [NodeID: [Int]] = [:]
    /// Each Merry-Go-Round's output (0-based) for every pass.
    private var deals: [NodeID: [Int]] = [:]

    /// The most combinations one batch makes.
    public static let maximumCombinations = 10_000

    /// `wordLists` are the words Random Words names are drawn from: BAKE's own, or the user's.
    public init(project: ProjectFile, files: [NodeID: [BatchFile]], wordLists: WordLists = .builtIn) {
        self.project = project
        self.files = files
        let outputs = project.nodes.filter(\.kind.isOutput).map(\.id)
        let feeding = ProjectFile.reach(from: outputs, along: project.orderingEdges(), forward: false)
        let matrix = project.nodes.first { $0.kind == .combinatorialMatrix && feeding.contains($0.id) }?.id
        self.matrix = matrix
        self.randomNames = [:]
        self.axes = matrix.map { matrix in
            ["a", "b", "c"].map { pin in
                let target = PinRef(node: matrix, pin: PinID(pin))
                var found: [NodeID] = []
                for edge in project.edges where edge.to == target {
                    for source in Self.sources(of: edge.from.node, in: project) where !found.contains(source) { found.append(source) }
                }
                return project.nodes.map(\.id).filter(found.contains)
            }
        } ?? []
        let passes = passCount
        var randomNames: [NodeID: [String]] = [:]
        for node in project.nodes where node.kind == .batchBake {
            let parameters = NodeCatalog.resolvedParameters(of: node)
            guard parameters["naming"] == .choice("random") else { continue }
            randomNames[node.id] = BatchNames.random(seed: Int(parameters["seed"]?.numberValue ?? 1), passes: passes, lists: wordLists)
        }
        self.randomNames = randomNames
        for node in project.nodes where node.kind == .merryGoRound {
            deals[node.id] = Self.merryGoRoundDeal(NodeCatalog.resolvedParameters(of: node), passes: passes)
        }
        if project.nodes.contains(where: { $0.kind == .forEachSplitter || $0.kind == .merryGoRound }) {
            let bakes = project.nodes.filter { $0.kind == .batchBake }.map(\.id)
            var counts: [NodeID: Int] = [:]
            var ordinals: [NodeID: [Int]] = [:]
            for index in 0..<passes {
                let out = Self.sittingOut(project, off: offPins(pass: index))
                for bake in bakes {
                    ordinals[bake, default: []].append(counts[bake] ?? 0)
                    if !out.contains(bake) { counts[bake, default: 0] += 1 }
                }
            }
            self.ordinals = ordinals
        }
    }

    // MARK: Routers

    /// Where each Spectral Sorter sent a pass: one of its outputs, or nil when it dropped the clip.
    public typealias Routes = [NodeID: PinID?]

    /// The router outputs that are off in pass `index`: a For Each Splitter's by its Mode, a Spectral Sorter's
    /// all but its route (none, before it's measured).
    public func offPins(pass index: Int, routes: Routes = [:]) -> Set<PinRef> {
        var off: Set<PinRef> = []
        for node in project.nodes where node.kind.isRouter {
            let pins = NodeCatalog.pins(of: node).filter { $0.direction == .output }.map(\.id)
            let on: Set<PinID>
            if node.kind == .spectralSorter {
                guard let route = routes[node.id] else { continue }
                on = route.map { [$0] } ?? []
            } else if node.kind == .merryGoRound {
                guard let deal = deals[node.id], index < deal.count else { continue }
                on = [PinID("out\(deal[index] + 1)")]
            } else {
                on = Self.splitterOutputs(NodeCatalog.resolvedParameters(of: node), pass: index, passes: passCount)
            }
            for pin in pins where !on.contains(pin) { off.insert(PinRef(node: node.id, pin: pin)) }
        }
        return off
    }

    /// Which output (0-based) a Merry-Go-Round deals each of `passes` passes to. Every Hold passes it takes a
    /// step: Forward 1, 2, 3, 1…; Ping-Pong 1, 2, 3, 2, 1, 2…; Random never the same output twice running (with
    /// two or more), a counter hash of Seed and step; Pattern the typed numbers in turn (above the output count
    /// they wrap; anything else is skipped; none at all is Forward).
    public static func merryGoRoundDeal(_ parameters: [ParameterID: ParameterValue], passes: Int) -> [Int] {
        let count = parameters["outputs"].flatMap { if case .choice(let value) = $0 { Int(value) } else { nil } } ?? 3
        let hold = max(1, Int(parameters["hold"]?.numberValue ?? 1))
        let seed = UInt64(max(0, parameters["seed"]?.numberValue ?? 1))
        let pattern = (parameters["pattern"]?.textValue ?? "")
            .split { !$0.isNumber }
            .compactMap { Int($0) }
            .filter { $0 >= 1 }
            .map { ($0 - 1) % count }
        var deal: [Int] = []
        deal.reserveCapacity(passes)
        var previous = -1
        for pass in 0..<passes {
            let step = pass / hold
            if pass % hold != 0, previous >= 0 {
                deal.append(previous)
                continue
            }
            let output: Int
            switch parameters["order"] {
            case .choice("pingPong")?:
                let period = max(1, 2 * (count - 1))
                let position = step % period
                output = position < count ? position : period - position
            case .choice("random")?:
                let value = ScatterSchedule.hash((seed << 32) ^ UInt64(step))
                if count < 2 || previous < 0 {
                    output = Int(value % UInt64(count))
                } else {
                    // One of the other outputs: skip over the last one.
                    let pick = Int(value % UInt64(count - 1))
                    output = pick >= previous ? pick + 1 : pick
                }
            case .choice("pattern")? where !pattern.isEmpty:
                output = pattern[step % pattern.count]
            default:
                output = step % count
            }
            deal.append(output)
            previous = output
        }
        return deal
    }

    /// The outputs a For Each Splitter's pass `index` goes down (of `passes`), by its Mode.
    public static func splitterOutputs(_ parameters: [ParameterID: ParameterValue], pass index: Int, passes: Int) -> Set<PinID> {
        let count = parameters["outputs"].flatMap { if case .choice(let value) = $0 { Int(value) } else { nil } } ?? 2
        let output: Int
        switch parameters["mode"] {
        case .choice("broadcast")?: return Set((1...count).map { PinID("out\($0)") })
        case .choice("oddEven")?: output = min(index % 2, count - 1)
        case .choice("blocks")?:
            let size = max(1, (passes + count - 1) / count)
            output = min(index / size, count - 1)
        default: output = index % count
        }
        return [PinID("out\(output + 1)")]
    }

    /// What sits a pass out: every node reached from an off output and not from an on one.
    static func sittingOut(_ project: ProjectFile, off: Set<PinRef>) -> Set<NodeID> {
        guard !off.isEmpty else { return [] }
        let routers = Array(Set(off.map(\.node)))
        let edges = project.orderingEdges()
        let before = ProjectFile.reach(from: routers, along: edges, forward: true)
        let after = ProjectFile.reach(from: routers, along: edges.filter { !off.contains($0.from) }, forward: true)
        return before.subtracting(after)
    }

    /// The Batch Bakes that write in pass `index`: those not behind an off router output.
    public func writingBakes(pass index: Int, routes: Routes = [:]) -> Set<NodeID> {
        let out = Self.sittingOut(project, off: offPins(pass: index, routes: routes))
        return Set(project.nodes.filter { $0.kind == .batchBake && !out.contains($0.id) }.map(\.id))
    }

    // MARK: Photo Booth

    /// The Photo Booths some output depends on: before the passes, what reaches them is captured once.
    public var photoBooths: [NodeID] {
        let outputs = project.nodes.filter { $0.kind.isOutput }.map(\.id)
        let feeding = ProjectFile.reach(from: outputs, along: project.orderingEdges(), forward: false)
        return project.nodes.filter { $0.kind == .photoBooth && feeding.contains($0.id) }.map(\.id)
    }

    /// Whether a node's batch waits on a Photo Booth whose trigger is wired: its chunks are only known once a
    /// bake has rendered the trigger.
    public func waitsForTriggers(_ node: NodeID) -> Bool {
        let wired = Set(project.edges.filter { $0.to.pin == "trigger" }.map(\.to.node))
        return sources(of: node).contains { source in
            project.node(source)?.kind == .photoBooth && wired.contains(source) && (files[source] ?? []).isEmpty
        }
    }

    /// What a Photo Booth's clips are named after: the first Audio file feeding it, or "booth".
    public func boothStem(of booth: NodeID) -> String {
        let upstream = ProjectFile.reach(from: [booth], along: project.orderingEdges(), forward: false)
        for node in project.nodes where node.kind == .audio && upstream.contains(node.id) {
            if let asset = node.assetID, let path = project.assets.first(where: { $0.id == asset })?.lastKnownPath {
                return URL(filePath: path).deletingPathExtension().lastPathComponent
            }
        }
        return "booth"
    }

    /// The hidden Bakes of a Photo Booth's capture: its input, and its trigger (carried on its output).
    public static func boothCaptures(of booth: NodeID) -> (input: NodeID, trigger: NodeID) {
        (NodeID(assetID(of: booth, pass: Int.max - 1).rawValue), NodeID(assetID(of: booth, pass: Int.max - 2).rawValue))
    }

    /// The patch that captures every Photo Booth: a hidden 32-bit float Bake of what reaches its input, and
    /// one of its output while it carries its trigger; nothing else. Nil without Photo Booths.
    public func photoBoothCapture() -> ProjectFile? {
        let booths = photoBooths
        guard !booths.isEmpty else { return nil }
        var capture = project
        capture.removeNodes(Set(project.nodes.filter { $0.kind.isOutput || $0.kind.isGather }.map(\.id)))
        capture.edges.removeAll { booths.contains($0.from.node) }
        for booth in booths {
            guard let i = capture.nodes.firstIndex(where: { $0.id == booth }) else { continue }
            capture.nodes[i].parameters["capture"] = .choice("on")
            let (input, trigger) = Self.boothCaptures(of: booth)
            for (id, name) in [(input, "booth-input"), (trigger, "booth-trigger")] {
                capture.nodes.append(Node(id: id, kind: .print, parameters: [
                    "prefix": .text("\(name)-\(booth.rawValue.uuidString)"), "bitDepth": .choice("32f"), "versions": .choice("overwrite"),
                ]))
            }
            if let feed = project.edges.first(where: { $0.to == PinRef(node: booth, pin: "in") }) {
                capture.edges.append(Edge(from: feed.from, to: PinRef(node: input, pin: "in")))
            }
            capture.edges.append(Edge(from: PinRef(node: booth, pin: "out"), to: PinRef(node: trigger, pin: "in")))
        }
        return capture
    }

    /// The Spectral Sorters some output depends on: each pass, what reaches them is measured first.
    public var sorters: [NodeID] {
        let outputs = project.nodes.filter { $0.kind.isOutput }.map(\.id)
        let feeding = ProjectFile.reach(from: outputs, along: project.orderingEdges(), forward: false)
        return project.nodes.filter { $0.kind == .spectralSorter && feeding.contains($0.id) }.map(\.id)
    }

    /// The Batch Conforms some output depends on: each pass, what reaches them is measured first too.
    public var conforms: [NodeID] {
        let outputs = project.nodes.filter { $0.kind.isOutput }.map(\.id)
        let feeding = ProjectFile.reach(from: outputs, along: project.orderingEdges(), forward: false)
        return project.nodes.filter { $0.kind == .batchConform && feeding.contains($0.id) }.map(\.id)
    }

    /// Pass `index` up to its sorters and Batch Conforms: each one a hidden 32-bit float Bake of what reaches
    /// it (named `captureName(of:pass:)`), nothing else. Nil without either.
    public func measureProbe(_ index: Int) -> ProjectFile? {
        let sorters = Set(self.sorters + conforms)
        guard !sorters.isEmpty else { return nil }
        var probe = pass(index)
        for i in probe.nodes.indices where sorters.contains(probe.nodes[i].id) {
            probe.nodes[i].kind = .print
            probe.nodes[i].outputFolder = nil
            probe.nodes[i].parameters = [
                "prefix": .text(Self.captureName(of: probe.nodes[i].id, pass: index)),
                "bitDepth": .choice("32f"), "versions": .choice("overwrite"),
            ]
        }
        probe.edges.removeAll { sorters.contains($0.from.node) }
        probe.removeNodes(Set(project.nodes.filter { ($0.kind.isOutput || $0.kind.isGather) && !sorters.contains($0.id) }.map(\.id)))
        return probe
    }

    /// As many passes as the largest folder has files; with a matrix, every combination of its axes.
    public var passCount: Int {
        if !axes.allSatisfy(\.isEmpty) { return axisCounts.reduce(1, *) }
        return project.nodes.filter(\.kind.isBatchSource).map { files[$0.id]?.count ?? 0 }.max() ?? 0
    }

    /// How many files each axis steps through: its longest batch source's, or 1 for an input without one.
    public var axisCounts: [Int] {
        axes.map { sources in max(1, sources.map { files[$0]?.count ?? 0 }.max() ?? 0) }
    }

    /// Which file of each axis pass `index` uses: A-major, so C changes fastest.
    public func combination(_ index: Int) -> [Int] {
        let counts = axisCounts
        var rest = index
        var digits = [Int](repeating: 0, count: counts.count)
        for axis in counts.indices.reversed() {
            digits[axis] = rest % counts[axis]
            rest /= counts[axis]
        }
        return digits
    }

    /// The patch for one pass: a batch source becomes Audio playing its file, Batch Bake becomes Bake
    /// with its name. Node IDs are kept, so wires, modulation and card summaries line up. Skip
    /// becomes Overwrite: whether to render at all is decided before the pass.
    public func pass(_ index: Int, ordinals: [NodeID: Int] = [:]) -> ProjectFile {
        var pass = project
        for i in pass.nodes.indices where pass.nodes[i].kind.isBatchSource {
            let id = pass.nodes[i].id
            let wasBooth = pass.nodes[i].kind == .photoBooth
            guard let file = file(of: id, pass: index) else { continue }
            let asset = Self.assetID(of: id, pass: index)
            pass.assets.append(AssetReference(id: asset, lastKnownPath: file.path, bookmark: file.bookmark))
            pass.nodes[i].kind = .audio
            pass.nodes[i].assetID = asset
            pass.nodes[i].sourceFolder = nil
            // A Photo Booth's input and trigger were rendered once, when it was captured.
            if wasBooth { pass.edges.removeAll { $0.to.node == id && ($0.to.pin == "in" || $0.to.pin == "trigger") } }
        }
        if let matrix, let i = pass.nodes.firstIndex(where: { $0.id == matrix }) {
            pass.nodes[i].parameters["combination"] = .number(Double(index))
        }
        for i in pass.nodes.indices where pass.nodes[i].kind == .batchBake {
            let id = pass.nodes[i].id
            pass.nodes[i].kind = .print
            pass.nodes[i].parameters["prefix"] = .text(fileName(of: id, pass: index, ordinal: ordinals[id]))
            if pass.nodes[i].parameters["versions"] == .choice("skip") {
                pass.nodes[i].parameters["versions"] = .choice("overwrite")
            }
        }
        // A gather captures its input: a hidden 32-bit float Bake. What follows it renders after the passes.
        // Concatenate stays: it joins its inputs, and `batchPass` captures what it makes.
        let gathers = Set(self.gathers)
        for i in pass.nodes.indices where gathers.contains(pass.nodes[i].id) && pass.nodes[i].kind != .concatenate {
            pass.nodes[i].kind = .print
            pass.nodes[i].outputFolder = nil
            pass.nodes[i].parameters = [
                "prefix": .text(Self.captureName(of: pass.nodes[i].id, pass: index)),
                "bitDepth": .choice("32f"), "versions": .choice("overwrite"),
            ]
        }
        pass.edges.removeAll { gathers.contains($0.from.node) }
        return pass
    }

    /// The gathers some output depends on; one that feeds nothing isn't captured. A Concatenate is one only
    /// with a batch before it; otherwise it simply joins its inputs.
    public var gathers: [NodeID] {
        let outputs = project.nodes.filter { $0.kind.isOutput }.map(\.id)
        let feeding = ProjectFile.reach(from: outputs, along: project.orderingEdges(), forward: false)
        return project.nodes.filter { node in
            node.kind.isGather && feeding.contains(node.id)
                && (node.kind != .concatenate || sources(of: node.id).contains { $0 != node.id })
        }.map(\.id)
    }

    /// A gather's capture in a pass: the file name its hidden Bake writes.
    public static func captureName(of gather: NodeID, pass: Int) -> String {
        "capture-\(gather.rawValue.uuidString)-\(pass)"
    }

    /// Whether `node` comes after a gather: it renders once, after the passes.
    public func dependsOnGather(_ node: NodeID) -> Bool {
        let upstream = ProjectFile.reach(from: [node], along: project.orderingEdges(), forward: false)
        let gathers = Set(self.gathers)
        return project.nodes.contains { gathers.contains($0.id) && $0.id != node && upstream.contains($0.id) }
    }

    /// The patch after the passes: each gather plays its joined file (`joined[gather]`, added as an
    /// asset), with its inputs cut; only the outputs after a gather are kept. Nil when there are none.
    public func afterPass(joined: [NodeID: AssetReference]) -> ProjectFile? {
        let outputs = project.nodes.filter { $0.kind.isOutput && dependsOnGather($0.id) }.map(\.id)
        guard !outputs.isEmpty else { return nil }
        var after = project
        after.removeNodes(Set(project.nodes.filter { $0.kind.isOutput && !outputs.contains($0.id) }.map(\.id)))
        let gathers = Set(self.gathers)
        for i in after.nodes.indices where gathers.contains(after.nodes[i].id) {
            let id = after.nodes[i].id
            guard let asset = joined[id] else { continue }
            after.assets.append(asset)
            after.nodes[i].kind = .audio
            after.nodes[i].assetID = asset.id
            after.nodes[i].parameters = [:]
            after.edges.removeAll { $0.to.node == id }
        }
        return after
    }

    /// Whether anything here bakes a batch: a Batch Bake, a gather, or an output fed by a batch source.
    public var hasBatch: Bool {
        !gathers.isEmpty || project.nodes.contains { $0.kind == .batchBake || ($0.kind.isOutput && !sources(of: $0.id).isEmpty) }
    }

    /// What renders once before the passes: the patch's Bakes and Previews that don't come after a
    /// gather (a batch source plays its first file there); nil when there are none.
    public func singlePass() -> ProjectFile? {
        let outputs = project.nodes.filter { ($0.kind == .print || $0.kind == .preview) && !dependsOnGather($0.id) }.map(\.id)
        guard !outputs.isEmpty else { return nil }
        var single = pass(0)
        let gathers = Set(self.gathers)
        single.removeNodes(Set(project.nodes.filter { ($0.kind.isOutput || gathers.contains($0.id)) && !outputs.contains($0.id) }.map(\.id)))
        return single
    }

    /// Pass `index` with its Batch Bakes (as Bakes, less `skipping`) and its gathers' captures, less what
    /// sits the pass out behind an off router output (`routes`: where the sorters sent it); nil when
    /// nothing is left. `ordinals` number the Batch Bakes' files (see `fileName`).
    /// `settings` are set on nodes for this pass only (a Batch Conform's ratio and shift).
    public func batchPass(
        _ index: Int, skipping: Set<NodeID> = [], routes: Routes = [:], ordinals: [NodeID: Int] = [:],
        settings: [NodeID: [ParameterID: ParameterValue]] = [:]
    ) -> ProjectFile? {
        let out = Self.sittingOut(project, off: offPins(pass: index, routes: routes))
        let bakes = Set(project.nodes.filter { $0.kind == .batchBake }.map(\.id)).subtracting(skipping).subtracting(out)
        let captures = Set(gathers).subtracting(out)
        guard !bakes.isEmpty || !captures.isEmpty else { return nil }
        var batch = pass(index, ordinals: ordinals)
        for (node, values) in settings {
            guard let i = batch.nodes.firstIndex(where: { $0.id == node }) else { continue }
            batch.nodes[i].parameters.merge(values) { $1 }
        }
        batch.removeNodes(out)
        let gathers = Set(self.gathers)
        batch.removeNodes(Set(project.nodes.filter {
            ($0.kind.isOutput && !bakes.contains($0.id)) || (gathers.contains($0.id) && !captures.contains($0.id))
        }.map(\.id)))
        for join in captures where project.node(join)?.kind == .concatenate {
            batch.nodes.append(Node(id: Self.captureNode(of: join), kind: .print, parameters: [
                "prefix": .text(Self.captureName(of: join, pass: index)), "bitDepth": .choice("32f"), "versions": .choice("overwrite"),
            ]))
            batch.edges.append(Edge(from: PinRef(node: join, pin: "out"), to: PinRef(node: Self.captureNode(of: join), pin: "in")))
        }
        return batch
    }

    /// The hidden Bake that captures a Concatenate's join in each pass (other gathers become their own capture).
    public static func captureNode(of gather: NodeID) -> NodeID {
        NodeID(assetID(of: gather, pass: Int.max - 3).rawValue)
    }

    /// The file a Batch Audio node plays in a pass: on a matrix axis, that axis's file of the combination.
    public func file(of node: NodeID, pass: Int) -> BatchFile? {
        guard let list = files[node], !list.isEmpty else { return nil }
        if let axis = axes.firstIndex(where: { $0.contains(node) }) {
            return list[combination(pass)[axis] % list.count]
        }
        return list[pass % list.count]
    }

    /// The asset a Batch Audio node plays in a pass: the first 16 bytes of SHA-256(node ‖ pass), so
    /// the same every time.
    public static func assetID(of node: NodeID, pass: Int) -> AssetID {
        var bytes = Data()
        withUnsafeBytes(of: node.rawValue.uuid) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(pass).littleEndian) { bytes.append(contentsOf: $0) }
        let digest = Array(SHA256.hash(data: bytes))
        return AssetID(UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        )))
    }

    /// A Batch Bake's file name in a pass, by its Naming. `{source}` is the file of the first batch source
    /// (in node order) feeding it; Name + Number numbers the name after an underscore. `{n}` and Name +
    /// Number count `ordinal`: the files this Batch Bake wrote before (behind a For Each Splitter, worked
    /// out here; behind a Spectral Sorter, counted by the bake). Otherwise it is the pass.
    public func fileName(of bake: NodeID, pass: Int, ordinal: Int? = nil) -> String {
        let number = ordinal ?? ordinals[bake].flatMap { pass < $0.count ? $0[pass] : nil } ?? pass
        guard let node = project.node(bake) else { return "bake" }
        let parameters = NodeCatalog.resolvedParameters(of: node)
        if let names = randomNames[bake], pass < names.count { return names[pass] }
        let pattern = conformTokens(parameters["name"]?.textValue ?? "{source}", for: bake)
        let source = sourceName(of: bake, pass: pass)
        let named = BatchFileName.resolve(pattern, source: source, pass: number, count: passCount)
        guard parameters["naming"] == .choice("numbered") else { return named }
        let digits = Int(parameters["digits"].flatMap { if case .choice(let digits) = $0 { digits } else { nil } } ?? "3") ?? 3
        return BatchNames.numbered(named, pass: number, digits: digits)
    }

    /// The file the first batch source feeding `node` plays in a pass (a Batch Conform reads its name).
    public func sourceFile(of node: NodeID, pass: Int) -> BatchFile? {
        sources(of: node).lazy.compactMap { file(of: $0, pass: pass) }.first
    }

    /// `{bpm}` and `{key}`: the targets of the Batch Conform before `bake`, if there is one.
    private func conformTokens(_ pattern: String, for bake: NodeID) -> String {
        guard pattern.contains("{bpm}") || pattern.contains("{key}") else { return pattern }
        let upstream = ProjectFile.reach(from: [bake], along: project.orderingEdges(), forward: false)
        guard let conform = project.nodes.first(where: { $0.kind == .batchConform && upstream.contains($0.id) }) else {
            return pattern.replacingOccurrences(of: "{bpm}", with: "").replacingOccurrences(of: "{key}", with: "")
        }
        let parameters = NodeCatalog.resolvedParameters(of: conform)
        let bpm = parameters["targetBPM"]?.numberValue ?? 120
        let key = parameters["targetKey"].flatMap { if case .choice(let v) = $0 { v } else { nil } } ?? "C"
        return pattern
            .replacingOccurrences(of: "{bpm}", with: bpm.rounded() == bpm ? String(Int(bpm)) : String(format: "%.1f", bpm))
            .replacingOccurrences(of: "{key}", with: key)
    }

    /// `{source}` for a Batch Bake: the first batch source's file or, after the matrix, the combination's
    /// files joined by `+` (`kick01+sub03+room02`).
    private func sourceName(of bake: NodeID, pass: Int) -> String {
        if let matrix, ProjectFile.reach(from: [bake], along: project.orderingEdges(), forward: false).contains(matrix) {
            let names = axes.compactMap { $0.lazy.compactMap { file(of: $0, pass: pass) }.first?.name }
            if !names.isEmpty { return names.joined(separator: "+") }
        }
        return sources(of: bake).lazy.compactMap { file(of: $0, pass: pass) }.first?.name ?? "bake"
    }

    /// The batch sources feeding a node, in node order. The search stops at a gather: what comes after
    /// a Concatenate is one signal, not one per file.
    func sources(of node: NodeID) -> [NodeID] {
        Self.sources(of: node, in: project)
    }

    static func sources(of node: NodeID, in project: ProjectFile) -> [NodeID] {
        let edges = project.orderingEdges()
        var seen: Set<NodeID> = [node]
        var stack = [node]
        while let current = stack.popLast() {
            if current != node, project.node(current)?.kind.isGather == true { continue }
            for edge in edges where edge.to.node == current && seen.insert(edge.from.node).inserted {
                stack.append(edge.from.node)
            }
        }
        return project.nodes.filter { $0.kind.isBatchSource && seen.contains($0.id) }.map(\.id)
    }

    /// What stops a batch, found before anything renders. A Batch Audio that feeds no output is
    /// left alone, so baking an unrelated Bake isn't held up by it.
    public func issues() -> [BatchIssue] {
        var issues: [BatchIssue] = []
        let outputs = project.nodes.filter(\.kind.isOutput).map(\.id)
        let feeding = ProjectFile.reach(from: outputs, along: project.orderingEdges(), forward: false)
        for node in project.nodes {
            switch node.kind {
            case .batchAudio where !feeding.contains(node.id), .largeAudio where !feeding.contains(node.id):
                break
            case .largeAudio where node.assetID == nil:
                issues.append(.noFile(node.id))
            case .largeAudio where (files[node.id] ?? []).isEmpty:
                issues.append(.noSlices(node.id))
            case .batchAudio where node.sourceFolder == nil:
                issues.append(.noFolder(node.id))
            case .batchAudio where (files[node.id] ?? []).isEmpty:
                issues.append(.emptyFolder(node.id))
            case .batchBake where sources(of: node.id).isEmpty:
                issues.append(dependsOnGather(node.id) ? .batchBakeAfterGather(node.id) : .noBatchSource(node.id))
            case .batchBake where node.parameters["versions"] == .choice("overwrite")
                && (node.parameters["naming"] ?? .choice("source")) == .choice("source")
                && !BatchFileName.varies(node.parameters["name"]?.textValue ?? "{source}"):
                issues.append(.sameNameEveryPass(node.id))
            case .photoBooth where feeding.contains(node.id) && sources(of: node.id).contains(where: { $0 != node.id }):
                issues.append(.batchIntoPhotoBooth(node.id))
            case .combinatorialMatrix where feeding.contains(node.id) && node.id != matrix:
                issues.append(.twoMatrices(node.id))
            case .combinatorialMatrix where node.id == matrix && passCount > Self.maximumCombinations:
                issues.append(.tooManyCombinations(node.id))
            case .print where !sources(of: node.id).isEmpty:
                issues.append(.plainBakeInBatch(node.id))
            default:
                break
            }
        }
        return issues
    }
}

/// A problem that stops a batch bake, on the card it belongs to.
public enum BatchIssue: Hashable, Sendable {
    case noFolder(NodeID)
    case emptyFolder(NodeID)
    case noBatchSource(NodeID)
    case plainBakeInBatch(NodeID)
    case sameNameEveryPass(NodeID)
    case noFile(NodeID)
    case noSlices(NodeID)
    case gatherWithoutBatch(NodeID)
    case batchBakeAfterGather(NodeID)
    case twoMatrices(NodeID)
    case tooManyCombinations(NodeID)
    case batchIntoPhotoBooth(NodeID)

    public var node: NodeID {
        switch self {
        case .noFolder(let node), .emptyFolder(let node), .noBatchSource(let node),
             .plainBakeInBatch(let node), .sameNameEveryPass(let node), .noFile(let node), .noSlices(let node),
             .gatherWithoutBatch(let node), .batchBakeAfterGather(let node), .twoMatrices(let node),
             .tooManyCombinations(let node), .batchIntoPhotoBooth(let node): node
        }
    }

    public var message: String {
        switch self {
        case .noFolder: "Choose a folder of audio files."
        case .emptyFolder: "This folder has no audio files this node can play."
        case .noBatchSource: "Connect a Batch Audio or Large Audio Processor before this Batch Bake. For one file, use Bake."
        case .plainBakeInBatch: "Use Batch Bake to write one file per input."
        case .sameNameEveryPass: "Every file would get the same name and replace the last. Put {source} or {n} in the name."
        case .noFile: "Choose a long recording to slice."
        case .noSlices: "No slices: nothing here is louder than the Threshold, or it's all shorter than Min Length."
        case .gatherWithoutBatch: "Connect a Batch Audio or Large Audio Processor before Concatenate."
        case .batchBakeAfterGather: "After Concatenate there's one file: use Bake."
        case .twoMatrices: "A batch can combine for one Combinatorial Matrix. Remove this one, or bake it separately."
        case .tooManyCombinations: "More than 10,000 combinations. Use fewer files on A, B or C."
        case .batchIntoPhotoBooth: "Photo Booth takes one signal, not a batch: connect an Audio, a Generator or an effect chain."
        }
    }
}

import BakeGraph
import BakeRender
import Foundation
import Observation

public enum BakeState: Equatable, Sendable {
    case idle
    /// 0…1 across all steps.
    case baking(progress: Double)
    case finished(outputs: [URL])
    case failed(GraphIssues)
    case cancelled
    /// A Preview node's render is ready to play.
    case previewReady(node: NodeID, url: URL)
}

/// Bakes a project: resolves its files, compiles, renders off the main actor with progress, and
/// turns every failure into problems on nodes and pins. One bake at a time.
@MainActor @Observable
public final class BakeSession {
    public private(set) var state: BakeState = .idle
    private let access: any FileAccess
    private var task: Task<Void, Never>?

    /// Where Preview nodes render. Per session, so two windows never share a preview file; the
    /// system clears temporary files.
    public let previewFolder: URL

    public init(access: any FileAccess = SecurityScopedFileAccess()) {
        self.access = access
        previewFolder = FileManager.default.temporaryDirectory
            .appending(path: "BAKE Previews/\(UUID().uuidString)", directoryHint: .isDirectory)
        // A failure here surfaces as a write problem when a preview renders.
        try? FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)
    }

    public var isBaking: Bool {
        if case .baking = state { true } else { false }
    }

    /// Problems from the last failed bake, for the canvas.
    public var issues: GraphIssues {
        if case .failed(let issues) = state { issues } else { GraphIssues() }
    }

    /// Starts baking a copy of `project` — every Bake node, or `only` one of them. `onFilesResolved`
    /// receives the bake's file resolution (with references refreshed for moved files) once the bake
    /// ends, to write back into the document. With `embedWorkflow` off (Settings), the WAVs are plain.
    public func bake(
        _ project: ProjectFile, only node: NodeID? = nil, embedWorkflow: Bool = true,
        onFilesResolved: @escaping @MainActor (ResolvedFiles) -> Void = { _ in }
    ) {
        guard !isBaking else { return }
        // The WAVs carry the whole patch as it is now, not the trimmed copy that renders.
        let workflow = embedWorkflow ? project : nil
        let project = node.map { project.keepingOnlyOutput($0) } ?? project.withoutPreviews()
        state = .baking(progress: 0)
        let access = self.access
        let previewFolder = self.previewFolder
        let media = collectedMedia
        let fingerprints = project.upstreamFingerprints()
        task = Task {
            let (outcome, files, summaries) = await Self.run(project, workflow: workflow, access: access, media: media, previewFolder: previewFolder, wordLists: wordLists) { fraction in
                Task { @MainActor in self.report(fraction) }
            }
            if case .finished = outcome { record(summaries, of: project, fingerprints: fingerprints) }
            state = outcome
            onFilesResolved(files)
        }
    }

    /// Renders one Preview node's path into `previewFolder` and reads its waveform. Ends in
    /// `.previewReady` (the app starts playback) or the same failures as a bake.
    public func preview(
        _ project: ProjectFile, node: NodeID,
        onFilesResolved: @escaping @MainActor (ResolvedFiles) -> Void = { _ in }
    ) {
        guard !isBaking else { return }
        let project = project.keepingOnlyOutput(node)
        state = .baking(progress: 0)
        let access = self.access
        let previewFolder = self.previewFolder
        let media = collectedMedia
        let fingerprints = project.upstreamFingerprints()
        task = Task {
            let (outcome, files, summaries) = await Self.run(project, access: access, media: media, previewFolder: previewFolder, wordLists: wordLists) { fraction in
                Task { @MainActor in self.report(fraction) }
            }
            if case .finished = outcome { record(summaries, of: project, fingerprints: fingerprints) }
            if case .finished(let outputs) = outcome, let url = outputs.first {
                previewWaveforms[node] = await Self.readPeaks(url)
                state = .previewReady(node: node, url: url)
            } else {
                state = outcome
            }
            onFilesResolved(files)
        }
    }

    /// The words Random Words names are drawn from (Settings › Random Names); BAKE's own by default.
    public var wordLists: WordLists = .builtIn

    /// The document's collected audio, unpacked (`MediaCache`), by package path. Collected assets are
    /// found here before their bookmarks and paths.
    public var collectedMedia: [String: URL] = [:]

    /// Each Preview node's last render, for its card.
    public private(set) var previewWaveforms: [NodeID: WaveformPeaks] = [:]

    /// What each node produced the last time a bake or preview ran it: its waveform and spectrogram,
    /// for the node's card. Each node shows its first output.
    public private(set) var nodeSummaries: [NodeID: NodeSummary] = [:]
    /// The same, for every output pin that was rendered, so a wire from a node's second output (the
    /// Pitch Follower's Confidence) can show that output. Goes stale with its node.
    public private(set) var outputSummaries: [PinRef: NodeSummary] = [:]
    private var summaryFingerprints: [NodeID: Int] = [:]

    /// The nodes whose summary no longer matches `project`: something in them, or feeding them, has
    /// changed since they were rendered. Moving a card changes nothing.
    public func staleSummaryNodes(in project: ProjectFile) -> Set<NodeID> {
        let current = project.upstreamFingerprints()
        return Set(nodeSummaries.keys.filter { current[$0] != summaryFingerprints[$0] })
    }

    private func record(_ summaries: [PinRef: NodeSummary], of project: ProjectFile, fingerprints: [NodeID: Int]) {
        outputSummaries.merge(summaries) { _, new in new }
        for node in project.nodes {
            guard let pin = NodeCatalog.pins(of: node, in: project).first(where: { $0.direction == .output })?.id,
                  let summary = summaries[PinRef(node: node.id, pin: pin)] else { continue }
            nodeSummaries[node.id] = summary
            summaryFingerprints[node.id] = fingerprints[node.id]
        }
    }

    @concurrent
    nonisolated private static func readPeaks(_ url: URL) async -> WaveformPeaks? {
        try? WaveformReader.peaks(of: url)
    }

    public func cancel() {
        task?.cancel()
    }

    /// Problems describe the graph as it was baked; once it changes they're stale.
    public func projectDidChange() {
        if case .failed = state { state = .idle }
    }

    /// Source file metadata for output-length previews, keyed by asset.
    public private(set) var assetInfo: [AssetID: AssetInfo] = [:]
    /// Source file waveforms, for Audio cards.
    public private(set) var assetWaveforms: [AssetID: WaveformPeaks] = [:]
    /// The project's audio files that can't be found or read right now (their cards offer Locate…).
    public private(set) var missingAssets: Set<AssetID> = []

    /// Each batch source's files: a Batch Audio's folder as it lists now, or a Large Audio Processor's
    /// slices (counted; their clips are written when a bake needs them). The first file's info is in
    /// `assetInfo` under `BatchRun.assetID(of:pass: 0)`, and a Batch Audio's first waveform in `assetWaveforms`.
    public private(set) var batchFiles: [NodeID: [BatchFile]] = [:]
    /// Each Large Audio Processor's slice starts, as fractions of its file, for the ticks on its card.
    public private(set) var sliceMarks: [NodeID: [Double]] = [:]

    /// Re-reads source file headers and waveforms (off the main actor). Call when the document's
    /// assets change, or a batch source's folder or settings do.
    public func refreshAssetInfo(for project: ProjectFile) async {
        let read = await Self.readAssetInfo(project, access: access, media: collectedMedia)
        (assetInfo, assetWaveforms, batchFiles, sliceMarks) = (read.infos, read.waveforms, read.listing.files, read.listing.marks)
        missingAssets = Set(project.assets.map(\.id)).subtracting(assetInfo.keys)
    }

    @concurrent
    nonisolated private static func readAssetInfo(
        _ project: ProjectFile, access: any FileAccess, media: [String: URL]
    ) async -> (infos: [AssetID: AssetInfo], waveforms: [AssetID: WaveformPeaks], listing: BatchListing) {
        let files = FileResolver.resolve(project, access: access, media: media)
        defer { files.release(using: access) }
        var infos: [AssetID: AssetInfo] = [:]
        var waveforms: [AssetID: WaveformPeaks] = [:]
        var urls = files.assetURLs
        let listing = batchFiles(of: project, in: files, writingClips: false)
        for node in project.nodes where node.kind == .batchAudio {
            if let first = listing.files[node.id]?.first { urls[BatchRun.assetID(of: node.id, pass: 0)] = URL(filePath: first.path) }
        }
        for (id, url) in urls {
            infos[id] = try? AssetInfoReader.info(for: url)
            waveforms[id] = try? WaveformReader.peaks(of: url)
        }
        for (node, first) in listing.firstSlice { infos[BatchRun.assetID(of: node, pass: 0)] = first }
        return (infos, waveforms, listing)
    }

    public func waitUntilFinished() async {
        await task?.value
    }

    private func report(_ fraction: Double) {
        // Progress updates can arrive after the bake ends; only move forward while baking.
        guard case .baking(let current) = state, fraction >= 1 || fraction - current >= 0.01 else { return }
        state = .baking(progress: fraction)
    }

    @concurrent
    nonisolated private static func run(
        _ project: ProjectFile, workflow: ProjectFile? = nil, access: any FileAccess, media: [String: URL], previewFolder: URL,
        wordLists: WordLists,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> (BakeState, ResolvedFiles, [PinRef: NodeSummary]) {
        let files = FileResolver.resolve(project, access: access, media: media)
        defer { files.release(using: access) }
        var problems = GraphIssues()
        var directories: [NodeID: URL] = [:]
        for node in project.nodes where node.kind.isOutput {
            if node.kind == .preview {
                directories[node.id] = previewFolder
            } else if node.outputFolder != nil {
                if let url = files.outputFolders[node.id] {
                    directories[node.id] = url
                } else {
                    problems.add("This node's folder can't be found — choose it again.", to: node.id)
                }
            } else if project.settings.printFolder == nil {
                problems.add("Choose a folder for this Bake node, or a default folder in the toolbar.", to: node.id)
            } else if files.printFolder == nil {
                problems.add("The default folder can't be found — choose it again in the toolbar.", to: node.id)
            }
        }
        var listing = batchFiles(of: project, in: files, writingClips: true)
        // A Photo Booth's clips come from a signal: what reaches it is captured once, then cut at its triggers.
        let booths = previewFolder.appending(path: "Photo Booth \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: booths) }
        let unplanned = BatchRun(project: project, files: listing.files, wordLists: wordLists)
        if let capture = unplanned.photoBoothCapture(),
           !unplanned.issues().contains(where: { if case .batchIntoPhotoBooth = $0 { true } else { false } }) {
            do {
                try FileManager.default.createDirectory(at: booths, withIntermediateDirectories: true)
                let plan = try GraphCompiler.compile(capture, assets: try AssetInfoReader.infos(for: files.assetURLs))
                var folders: [NodeID: URL] = [:]
                for booth in unplanned.photoBooths {
                    let (input, trigger) = BatchRun.boothCaptures(of: booth)
                    folders[input] = booths
                    folders[trigger] = booths
                }
                let result = try await RenderEngine.render(RenderRequest(
                    plan: plan, assetURLs: files.assetURLs, outputDirectory: booths, outputDirectories: folders
                ))
                for booth in unplanned.photoBooths {
                    guard let node = project.node(booth) else { continue }
                    let (input, trigger) = BatchRun.boothCaptures(of: booth)
                    guard let inputURL = result.outputs[input], let triggerURL = result.outputs[trigger] else { continue }
                    listing.files[booth] = try PhotoBoothClips.clips(
                        input: inputURL, trigger: triggerURL, parameters: NodeCatalog.resolvedParameters(of: node),
                        stem: unplanned.boothStem(of: booth), into: booths
                    )
                }
            } catch {
                for booth in unplanned.photoBooths {
                    problems.add("Couldn't capture what reaches this Photo Booth. Check the nodes before it.", to: booth)
                }
            }
        }
        let batch = BatchRun(project: project, files: listing.files, wordLists: wordLists)
        if batch.hasBatch {
            for (node, message) in listing.problems { problems.add(message, to: node) }
            for issue in batch.issues() where listing.problems[issue.node] == nil { problems.add(issue.message, to: issue.node) }
        }
        guard problems.isEmpty else { return (.failed(problems), files, [:]) }
        // Only used by nodes without their own folder, which the checks above guarantee has resolved.
        let folder = files.printFolder ?? FileManager.default.temporaryDirectory
        // Each pass writes what reaches a gather or a sorter here; the joined files go here too. Gone when the bake ends.
        let gathers = batch.gathers
        let sorters = batch.sorters
        let conforms = batch.conforms
        let captures = previewFolder.appending(path: "Gather \(UUID().uuidString)", directoryHint: .isDirectory)
        let capturing = !gathers.isEmpty || !sorters.isEmpty || !conforms.isEmpty
        if capturing {
            try? FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
            for node in gathers + sorters + conforms { directories[node] = captures }
            for node in gathers { directories[BatchRun.captureNode(of: node)] = captures }
        }
        defer { if capturing { try? FileManager.default.removeItem(at: captures) } }
        do throws(any Error) {
            let infos = try AssetInfoReader.infos(for: files.assetURLs)
            // Every file of a batch is read before the first is written, so a bad one can't stop it halfway.
            var batchInfos: [String: AssetInfo] = [:]
            for node in project.nodes where node.kind.isBatchSource {
                for file in batch.files[node.id] ?? [] where batchInfos[file.path] == nil {
                    guard let info = try? AssetInfoReader.info(for: URL(filePath: file.path)) else {
                        problems.add("Can't read “\(URL(filePath: file.path).lastPathComponent)”. Remove it from the folder or fix it.", to: node.id)
                        return (.failed(problems), files, [:])
                    }
                    batchInfos[file.path] = info
                }
            }
            let passes = project.nodes.contains { $0.kind == .batchBake } || !gathers.isEmpty ? batch.passCount : 0
            // With nothing to bake at all, the patch itself compiles, so its problem ("no output") is reported.
            let single = batch.singlePass() ?? (passes == 0 ? project : nil)
            let hasAfter = !gathers.isEmpty && project.nodes.contains { $0.kind.isOutput && batch.dependsOnGather($0.id) }
            // A pass with sorters renders twice: up to the sorters (to measure), then the rest.
            // Each gather's combine is a step of its own: averaging 1 800 spectra takes a while.
            let total = Double((single == nil ? 0 : 1) + passes * (sorters.isEmpty && conforms.isEmpty ? 1 : 2)
                + (hasAfter ? 1 + gathers.count : 0))
            var outputs: [URL] = []
            var summaries: [PinRef: NodeSummary] = [:]
            var done = 0.0
            func render(_ pass: ProjectFile, index: Int, joined: [AssetID: URL] = [:]) async throws {
                var assetURLs = files.assetURLs.merging(joined) { $1 }
                var assetInfos = infos
                for (asset, url) in joined { assetInfos[asset] = try AssetInfoReader.info(for: url) }
                // The after stage (index −1) plays the joined files, not a pass's.
                for node in project.nodes where node.kind.isBatchSource && index >= 0 {
                    guard let file = batch.file(of: node.id, pass: index) else { continue }
                    let asset = BatchRun.assetID(of: node.id, pass: index)
                    assetURLs[asset] = URL(filePath: file.path)
                    assetInfos[asset] = batchInfos[file.path]
                }
                let plan = try GraphCompiler.compile(pass, assets: assetInfos)
                let request = RenderRequest(
                    plan: plan, assetURLs: assetURLs, outputDirectory: folder, outputDirectories: directories,
                    collectSummaries: index == 0 || !joined.isEmpty, workflow: workflow
                )
                let start = done
                let result = try await RenderEngine.render(request) { progress((start + $0.fraction) / total) }
                // Captures are scratch, not results.
                let scratch = Set(gathers + sorters + conforms + gathers.map(BatchRun.captureNode(of:)))
                outputs += result.outputs.filter { !scratch.contains($0.key) }.values
                summaries.merge(result.summaries) { _, new in new }
                done += 1
            }
            if let single { try await render(single, index: 0) }
            // Behind a sorter, each Batch Bake numbers the files it has written so far.
            var written: [NodeID: Int] = [:]
            for index in 0..<passes {
                try Task.checkCancellation()
                // A sorter sends the pass where its measure of what reached it says.
                var routes: BatchRun.Routes = [:]
                var settings: [NodeID: [ParameterID: ParameterValue]] = [:]
                if let probe = batch.measureProbe(index) {
                    try await render(probe, index: index)
                    // A Batch Conform's ratio and shift for this pass, from the file's name or what reached it.
                    for conform in conforms {
                        guard let node = project.node(conform) else { continue }
                        let name = RenderEngine.bakeFileName(.text(BatchRun.captureName(of: conform, pass: index)))
                        let url = captures.appending(path: name).appendingPathExtension("wav")
                        let parameters = NodeCatalog.resolvedParameters(of: node)
                        let detected = try ConformMeasure.measure(
                            url, target: parameters["targetBPM"]?.numberValue ?? 120, sampleRate: project.settings.sampleRate
                        )
                        let plan = ConformPlan.settings(
                            parameters, name: batch.sourceFile(of: conform, pass: index)?.name,
                            detectedBPM: detected.bpm, detectedKey: detected.key
                        )
                        settings[conform] = ["ratio": .number(plan.ratio), "shift": .number(Double(plan.shift))]
                        try? FileManager.default.removeItem(at: url)
                    }
                    for sorter in sorters {
                        guard let node = project.node(sorter) else { continue }
                        let name = RenderEngine.bakeFileName(.text(BatchRun.captureName(of: sorter, pass: index)))
                        let url = captures.appending(path: name).appendingPathExtension("wav")
                        let parameters = NodeCatalog.resolvedParameters(of: node)
                        let value = try SortMeasure.measure(url, parameters: parameters, sampleRate: project.settings.sampleRate)
                        routes[sorter] = SorterRoute.route(value, parameters: parameters)
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                let ordinals = sorters.isEmpty ? [:] : written
                // Skip: a Batch Bake whose file for this pass is already there leaves it alone.
                let skipping = Set(project.nodes.filter { node in
                    guard node.kind == .batchBake, NodeCatalog.resolvedParameters(of: node)["versions"] == .choice("skip") else { return false }
                    let name = RenderEngine.bakeFileName(.text(batch.fileName(of: node.id, pass: index, ordinal: ordinals[node.id])))
                    let url = (directories[node.id] ?? folder).appending(path: name).appendingPathExtension("wav")
                    return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                }.map(\.id))
                if let pass = batch.batchPass(index, skipping: skipping, routes: routes, ordinals: ordinals, settings: settings) {
                    try await render(pass, index: index)
                } else {
                    done += 1
                    progress(done / total)
                }
                if !sorters.isEmpty {
                    for bake in batch.writingBakes(pass: index, routes: routes) { written[bake, default: 0] += 1 }
                }
            }
            // After the passes: each gather's captures joined, then what follows the gathers, once.
            if hasAfter {
                try Task.checkCancellation()
                var joined: [NodeID: AssetReference] = [:]
                var urls: [AssetID: URL] = [:]
                for gather in gathers {
                    let clips = (0..<passes).map {
                        captures.appending(path: RenderEngine.bakeFileName(.text(BatchRun.captureName(of: gather, pass: $0)))).appendingPathExtension("wav")
                    }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
                    guard !clips.isEmpty, let node = project.node(gather) else { continue }
                    let url = captures.appending(path: "joined \(gather.rawValue.uuidString).wav")
                    let parameters = NodeCatalog.resolvedParameters(of: node)
                    let rate = project.settings.sampleRate
                    switch node.kind {
                    case .corpusScatter: try Scatter.render(clips, parameters: parameters, sampleRate: rate, to: url)
                    case .ensembleAverager:
                        let start = done
                        try EnsembleAverager.render(clips, parameters: parameters, sampleRate: rate, to: url) { progress((start + $0) / total) }
                    default: try Concatenation.join(clips, parameters: parameters, to: url)
                    }
                    done += 1
                    progress(done / total)
                    let asset = AssetReference(lastKnownPath: url.path(percentEncoded: false))
                    joined[gather] = asset
                    urls[asset.id] = url
                }
                if let after = batch.afterPass(joined: joined) {
                    try await render(after, index: -1, joined: urls)
                }
            }
            return (.finished(outputs: outputs.sorted { $0.lastPathComponent < $1.lastPathComponent }), files, summaries)
        } catch let failure as CompileFailure {
            return (.failed(GraphIssues(failure, in: project)), files, [:])
        } catch let error as RenderError {
            return (.failed(GraphIssues(error, in: project, files: files)), files, [:])
        } catch is CancellationError {
            return (.cancelled, files, [:])
        } catch {
            return (.failed(general(error.localizedDescription)), files, [:])
        }
    }

    /// What each batch source plays, and what went wrong reading it.
    struct BatchListing: Sendable {
        var files: [NodeID: [BatchFile]] = [:]
        /// Large Audio Processor: where its slices start (fractions of the file), and its first slice's shape.
        var marks: [NodeID: [Double]] = [:]
        var firstSlice: [NodeID: AssetInfo] = [:]
        /// A long file that can't be found or read, by node.
        var problems: [NodeID: String] = [:]
    }

    /// Where Large Audio Processors keep their analysis and clips, shared by every window.
    nonisolated static let sliceCache = FileManager.default.temporaryDirectory.appending(path: "BAKE Slices", directoryHint: .isDirectory)

    /// Each batch source's files. A Batch Audio's resolved folder, listed by its settings. A Large Audio
    /// Processor's slices: their clips when `writingClips` (a bake), otherwise one placeholder per slice
    /// (enough to count them, with the first slice's shape for the card lengths).
    nonisolated static func batchFiles(of project: ProjectFile, in files: ResolvedFiles, writingClips: Bool) -> BatchListing {
        var listing = BatchListing()
        for node in project.nodes where node.kind == .batchAudio {
            guard let folder = files.sourceFolders[node.id] else { continue }
            listing.files[node.id] = BatchFolder.files(
                in: folder, parameters: NodeCatalog.resolvedParameters(of: node), sampleRate: project.settings.sampleRate
            ) { try? AssetInfoReader.info(for: $0) }.map { BatchFile(path: $0.path(percentEncoded: false)) }
        }
        for node in project.nodes where node.kind == .largeAudio {
            guard let asset = node.assetID else { continue }  // BatchRun asks for a file.
            guard let url = files.assetURLs[asset] else {
                listing.problems[node.id] = "This recording can't be found. Locate it on the card."
                continue
            }
            let parameters = NodeCatalog.resolvedParameters(of: node)
            do {
                let info = try AssetInfoReader.info(for: url)
                let slices = try SliceClips.slices(for: url, parameters: parameters, in: sliceCache)
                listing.marks[node.id] = slices.map { Double($0.lowerBound) / Double(max(info.frameCount, 1)) }
                if let first = slices.first {
                    listing.firstSlice[node.id] = AssetInfo(frameCount: first.count, channelCount: info.channelCount, sampleRate: info.sampleRate)
                }
                listing.files[node.id] = writingClips
                    ? try SliceClips.clips(for: url, parameters: parameters, in: sliceCache)
                    : slices.indices.map { BatchFile(path: "\(url.path(percentEncoded: false))#\($0 + 1)") }
            } catch {
                listing.problems[node.id] = "Can't read “\(url.lastPathComponent)”."
            }
        }
        return listing
    }

    nonisolated private static func general(_ message: String) -> GraphIssues {
        var issues = GraphIssues()
        issues.addGeneral(message)
        return issues
    }
}

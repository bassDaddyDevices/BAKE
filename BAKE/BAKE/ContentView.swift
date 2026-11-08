import AppKit
import BakeCanvas
import BakeGraph
import BakeSession
import SwiftUI
import UniformTypeIdentifiers

/// What the window's one file picker is choosing for.
private enum FilePick {
    case defaultFolder
    case nodeFolder(NodeID)
    case audio(NodeID)
    /// A missing audio file's new place: every node playing it follows.
    case locate(AssetID)
    /// A `.bakenode` to add, with its card's top-left here.
    case customNode(CanvasPoint)
    /// The folder a Batch Audio node plays.
    case sourceFolder(NodeID)

    var contentTypes: [UTType] {
        switch self {
        case .audio, .locate: [.audio]
        case .customNode: [.bakeNode]
        case .defaultFolder, .nodeFolder, .sourceFolder: [.folder]
        }
    }
}

/// The document window: the canvas, the Bake toolbar, and the bake status strip.
struct ContentView: View {
    @Binding var document: BakeDocument
    @State private var session = BakeSession()
    @State private var player = PreviewPlayer()
    /// One picker for the whole window — SwiftUI ignores pickers nested inside another.
    @State private var isPicking = false
    /// Kept apart from `isPicking`, which SwiftUI clears before the completion handler runs.
    @State private var pick: FilePick = .defaultFolder
    @State private var importProblem: String?
    /// The custom node library's files, for Add Node › Custom.
    @State private var library: [CustomNodeFile] = []
    /// Random Words names' lists (Settings), for the Batch Bake cards' first names; read again before each bake.
    @State private var wordLists = WordLists.builtIn
    @Environment(\.newDocument) private var newDocument
    @AppStorage(AppPreferences.embedWorkflowKey) private var embedWorkflow = true
    @AppStorage(AppPreferences.animateCardsKey) private var animateCards = true
    @AppStorage(AppPreferences.outputDeviceKey) private var outputDevice = ""

    var body: some View {
        WorkspaceView(
            project: $document.project, issues: session.issues, assetInfo: session.assetInfo,
            waveforms: waveforms, summaries: session.nodeSummaries, outputSummaries: session.outputSummaries,
            staleSummaries: session.staleSummaryNodes(in: document.project), playingPreview: player.playingNode,
            actions: actions
        )
            .environment(\.cardAnimations, animateCards)
            .frame(minWidth: 800, minHeight: 500)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BakeStatusBar(state: session.state, cancel: session.cancel)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { choose(.defaultFolder) } label: {
                        Label(printFolderName ?? "Default Folder…", systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Where Bake nodes write unless they have their own folder")
                    Button("Collect Files", systemImage: "tray.and.arrow.down", action: collectFiles)
                        .labelStyle(.titleAndIcon)
                        .disabled(!document.project.assets.contains { $0.packagePath == nil } || session.isBaking)
                        .help("Copy every audio file this project uses into it, so it keeps its sound wherever you move it")
                    Button("Bake All", systemImage: "flame", action: bakeAll)
                        .labelStyle(.titleAndIcon)
                        .keyboardShortcut("b", modifiers: .command)
                        .disabled(session.isBaking)
                        .help("Bake every Bake node's file (⌘B)")
                }
            }
            .fileImporter(isPresented: $isPicking, allowedContentTypes: pick.contentTypes) { result in
                guard case .success(let url) = result else { return }
                switch pick {
                case .defaultFolder: choosePrintFolder(url)
                case .nodeFolder(let node): chooseNodeFolder(node, url)
                case .audio(let node): importAudio(node, url)
                case .locate(let asset): relinkAudio(asset, url)
                case .customNode(let position): addCustomNodeFile(url, at: position)
                case .sourceFolder(let node): chooseSourceFolder(node, url)
                }
            }
            // Clear problems when the graph changes — not when a bake writes refreshed bookmarks back.
            .task(id: AssetRefresh(project: document.project)) { await session.refreshAssetInfo(for: document.project) }
            .task {
                library = CustomNodeLibrary.entries()
                wordLists = AppPreferences.wordLists()
            }
            // Collected audio is unpacked once into the cache, then the cards' file info is read again.
            .task(id: Set(document.media.keys)) {
                let media = document.media
                session.collectedMedia = await Task.detached { (try? MediaCache.unpack(media)) ?? [:] }.value
                await session.refreshAssetInfo(for: document.project)
            }
            .onChange(of: document.project.nodes) { session.projectDidChange() }
            .onChange(of: session.state) { _, state in
                if case .previewReady(let node, let url) = state {
                    player.outputDeviceUID = outputDevice
                    player.play(url, for: node)
                }
            }
            .onChange(of: document.project.edges) { session.projectDidChange() }
            .onChange(of: document.project.settings.printFolder == nil) { session.projectDidChange() }
            .alert("Can't Use This File", isPresented: Binding(get: { importProblem != nil }, set: { if !$0 { importProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importProblem ?? "")
            }
    }

    private var actions: NodeActions {
        var actions = NodeActions(
            importAudio: importAudio,
            chooseAudio: { choose(.audio($0)) },
            chooseFolder: { choose(.nodeFolder($0)) },
            bake: bakeNode,
            preview: { node in
                session.wordLists = AppPreferences.wordLists()
                session.preview(document.project, node: node, onFilesResolved: writeBack)
            },
            stopPreview: player.stop,
            // The patch inside a baked WAV opens as a new untitled document.
            openWorkflow: { newDocument(BakeDocument(project: $0.project)) },
            addAudio: addAudio,
            isBaking: session.isBaking
        )
        actions.customNodeLibrary = library
        actions.missingAssets = session.missingAssets
        actions.locateAudio = { node in
            if let asset = document.project.node(node)?.assetID { choose(.locate(asset)) }
        }
        actions.saveCustomNodeToLibrary = saveToLibrary
        actions.exportCustomNode = exportCustomNode
        actions.importCustomNode = { choose(.customNode($0)) }
        actions.addCustomNodeFile = addCustomNodeFile
        actions.batchFiles = session.batchFiles
        actions.sliceMarks = session.sliceMarks
        actions.wordLists = wordLists
        actions.chooseSourceFolder = { choose(.sourceFolder($0)) }
        actions.useSourceFolder = chooseSourceFolder
        return actions
    }

    private var printFolderName: String? {
        document.project.settings.printFolder.map { URL(filePath: $0.lastKnownPath).lastPathComponent }
    }

    /// Audio nodes show their source's waveform, Batch Audio nodes their first file's; Preview nodes
    /// their last render.
    private var waveforms: [NodeID: WaveformPeaks] {
        var waveforms = session.previewWaveforms
        for node in document.project.nodes {
            let asset = node.kind == .batchAudio ? BatchRun.assetID(of: node.id, pass: 0)
                : node.kind == .audio || node.kind == .largeAudio ? node.assetID : nil
            if let asset, let waveform = session.assetWaveforms[asset] {
                waveforms[node.id] = waveform
            }
        }
        return waveforms
    }

    private func choose(_ target: FilePick) {
        pick = target
        isPicking = true
    }

    private func bakeAll() {
        wordLists = AppPreferences.wordLists()
        session.wordLists = wordLists
        session.bake(document.project, embedWorkflow: embedWorkflow, onFilesResolved: writeBack)
    }

    private func bakeNode(_ node: NodeID) {
        wordLists = AppPreferences.wordLists()
        session.wordLists = wordLists
        session.bake(document.project, only: node, embedWorkflow: embedWorkflow, onFilesResolved: writeBack)
    }

    /// Stores references re-created for files and folders that moved since the last bake.
    private func writeBack(_ files: ResolvedFiles) {
        $document.project.edit {
            $0.updateFileReferences(
                assets: files.refreshedAssets, printFolder: files.refreshedPrintFolder, outputFolders: files.refreshedOutputFolders,
                sourceFolders: files.refreshedSourceFolders
            )
        }
    }

    /// An audio file dropped on the empty canvas: checked first, then one undoable edit adds the Audio
    /// node and loads it, so an unreadable file leaves nothing behind.
    private func addAudio(_ url: URL, at position: CanvasPoint) {
        do throws(ImportError) {
            let reference = try FileImport.audioReference(for: url, access: SecurityScopedFileAccess())
            $document.project.edit {
                let node = $0.addNode(.audio, at: position)
                $0.assignAudio(path: reference.lastKnownPath, bookmark: reference.bookmark, to: node)
            }
        } catch {
            switch error {
            case .unreadableAudio(let name):
                importProblem = "BAKE can't read “\(name)”. Use a WAV, AIFF, or CAF file."
            case .cantBookmark(let name):
                importProblem = "macOS wouldn't let BAKE keep access to “\(name)”."
            }
        }
    }

    /// Locate…: the missing file's reference now points here, so every node playing it follows. The
    /// asset list changes, so the cards' file info is read again and the Missing mark clears.
    private func relinkAudio(_ asset: AssetID, _ url: URL) {
        do throws(ImportError) {
            let reference = try FileImport.audioReference(for: url, access: SecurityScopedFileAccess())
            $document.project.edit { $0.relinkAsset(asset, path: reference.lastKnownPath, bookmark: reference.bookmark) }
        } catch {
            switch error {
            case .unreadableAudio(let name):
                importProblem = "BAKE can't read “\(name)”. Use a WAV, AIFF, or CAF file."
            case .cantBookmark(let name):
                importProblem = "macOS wouldn't let BAKE keep access to “\(name)”."
            }
        }
    }

    private func importAudio(_ node: NodeID, _ url: URL) {
        do throws(ImportError) {
            let reference = try FileImport.audioReference(for: url, access: SecurityScopedFileAccess())
            $document.project.edit { $0.assignAudio(path: reference.lastKnownPath, bookmark: reference.bookmark, to: node) }
        } catch {
            switch error {
            case .unreadableAudio(let name):
                importProblem = "BAKE can't read “\(name)”. Use a WAV, AIFF, or CAF file."
            case .cantBookmark(let name):
                importProblem = "macOS wouldn't let BAKE keep access to “\(name)”."
            }
        }
    }

    // MARK: Collect Files

    /// Copies every audio file the project uses (and hasn't collected yet) into the document, in one
    /// undo step. Files that can't be read right now stay as they are, and are listed.
    private func collectFiles() {
        let access = SecurityScopedFileAccess()
        let files = FileResolver.resolve(document.project, access: access, media: session.collectedMedia)
        defer { files.release(using: access) }
        var updated = document
        var taken = Set(updated.media.keys)
        var missed: [String] = []
        for asset in updated.project.assets where asset.packagePath == nil {
            let name = URL(filePath: asset.lastKnownPath).lastPathComponent
            guard let url = files.assetURLs[asset.id], let data = try? Data(contentsOf: url) else {
                missed.append(name)
                continue
            }
            let path = ProjectPackage.mediaPath(for: url.lastPathComponent, taken: taken)
            taken.insert(path)
            updated.media[path] = data
            updated.project.markCollected(asset.id, at: path)
        }
        document = updated
        if !missed.isEmpty {
            importProblem = "BAKE couldn't find \(missed.map { "“\($0)”" }.formatted()). Locate them, then collect again."
        }
    }

    // MARK: Custom node files

    private func customNodeFile(_ definition: UUID) -> CustomNodeFile? {
        document.project.customNodes.first { $0.id == definition }.map { CustomNodeFile(definition: $0, from: document.project) }
    }

    private func saveToLibrary(_ definition: UUID) {
        guard let file = customNodeFile(definition) else { return }
        do {
            try CustomNodeLibrary.save(file)
            library = CustomNodeLibrary.entries()
        } catch {
            importProblem = "BAKE couldn't save “\(file.definition.name)” to the library."
        }
    }

    private func exportCustomNode(_ definition: UUID) {
        guard let file = customNodeFile(definition) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.bakeNode]
        panel.nameFieldStringValue = "\(file.definition.name).\(CustomNodeFile.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try file.encoded().write(to: url, options: .atomic)
        } catch {
            importProblem = "BAKE couldn't write “\(url.lastPathComponent)”."
        }
    }

    /// A `.bakenode` picked or dropped: its custom node joins the document, its card at `position`.
    private func addCustomNodeFile(_ url: URL, at position: CanvasPoint) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try CustomNodeFile.decoded(try Data(contentsOf: url))
            $document.project.edit {
                let definition = $0.importCustomNode(file)
                $0.addCustomNode(definition, at: position)
            }
        } catch CustomNodeFileError.unsupportedFormat, CustomNodeFileError.unsupportedSchemaVersion {
            importProblem = "“\(url.lastPathComponent)” was made by a newer BAKE. Update BAKE to use it."
        } catch {
            importProblem = "BAKE can't read “\(url.lastPathComponent)” as a custom node."
        }
    }

    private func choosePrintFolder(_ url: URL) {
        do {
            let reference = try FileImport.folderReference(for: url, access: SecurityScopedFileAccess())
            $document.project.edit { $0.settings.printFolder = reference }
        } catch {
            importProblem = "macOS wouldn't let BAKE write to “\(url.lastPathComponent)”."
        }
    }

    private func chooseSourceFolder(_ node: NodeID, _ url: URL) {
        do {
            let reference = try FileImport.sourceFolderReference(for: url, access: SecurityScopedFileAccess())
            $document.project.edit { $0.setSourceFolder(reference, for: node) }
        } catch {
            importProblem = "macOS wouldn't let BAKE read “\(url.lastPathComponent)”."
        }
    }

    private func chooseNodeFolder(_ node: NodeID, _ url: URL) {
        do {
            let reference = try FileImport.folderReference(for: url, access: SecurityScopedFileAccess())
            $document.project.edit { $0.setOutputFolder(reference, for: node) }
        } catch {
            importProblem = "macOS wouldn't let BAKE write to “\(url.lastPathComponent)”."
        }
    }
}

/// What the cards' file info depends on: the audio files, and each batch source's folder and the
/// settings that pick its files or slices (not Gain, which only scales them). Re-read when any changes.
private struct AssetRefresh: Hashable {
    let assets: [AssetReference]
    let batch: [BatchSource]

    struct BatchSource: Hashable {
        let node: NodeID
        let folder: FileReference?
        let settings: [ParameterID: ParameterValue]
    }

    init(project: ProjectFile) {
        assets = project.assets
        batch = project.nodes.filter(\.kind.isBatchSource).map { node in
            BatchSource(node: node.id, folder: node.sourceFolder, settings: node.parameters.filter { $0.key != "gain" })
        }
    }
}

#Preview {
    ContentView(document: .constant(BakeDocument()))
}

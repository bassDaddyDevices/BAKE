import Foundation

extension ProjectFile {
    /// Points an Audio node at a file. One asset per path; assets no node uses are dropped.
    @discardableResult
    public mutating func assignAudio(path: String, bookmark: Data?, to node: NodeID) -> AssetID? {
        guard let index = index(of: node), nodes[index].kind == .audio || nodes[index].kind == .largeAudio else { return nil }
        let id: AssetID
        if let existing = assets.firstIndex(where: { $0.lastKnownPath == path }) {
            if let bookmark { assets[existing].bookmark = bookmark }
            id = assets[existing].id
        } else {
            id = AssetID()
            assets.append(AssetReference(id: id, lastKnownPath: path, bookmark: bookmark))
        }
        nodes[index].assetID = id
        pruneUnusedAssets()
        return id
    }

    public mutating func pruneUnusedAssets() {
        // Audio nodes inside custom nodes' definitions count too.
        let used = Set((nodes + customNodes.flatMap(\.nodes)).compactMap(\.assetID))
        assets.removeAll { !used.contains($0.id) }
    }

    /// Points an audio file reference at a new location (Locate…): every Audio node playing it, in the
    /// patch or inside a custom node, plays the new file. Returns how many nodes that is.
    @discardableResult
    public mutating func relinkAsset(_ id: AssetID, path: String, bookmark: Data?) -> Int {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return 0 }
        assets[index].lastKnownPath = path
        assets[index].bookmark = bookmark
        // Locating a file means using that file, not an earlier copy in the package.
        assets[index].packagePath = nil
        return (nodes + customNodes.flatMap(\.nodes)).count { $0.assetID == id }
    }

    /// Collect Files: the asset now plays its copy at `packagePath` inside the document. Its path and
    /// bookmark stay, so the original can still be found if the copy is ever missing.
    public mutating func markCollected(_ id: AssetID, at packagePath: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        assets[index].packagePath = packagePath
    }

    /// The file name an Audio node plays, for display.
    public func audioFileName(for node: NodeID) -> String? {
        guard let asset = self.node(node)?.assetID,
              let reference = assets.first(where: { $0.id == asset }) else { return nil }
        return URL(filePath: reference.lastKnownPath).lastPathComponent
    }

    /// Stores references re-created after files moved (from a bake's file resolution).
    public mutating func updateFileReferences(
        assets refreshed: [AssetID: FileReference], printFolder: FileReference?, outputFolders: [NodeID: FileReference] = [:],
        sourceFolders: [NodeID: FileReference] = [:]
    ) {
        for index in assets.indices {
            if let reference = refreshed[assets[index].id] {
                assets[index].lastKnownPath = reference.lastKnownPath
                assets[index].bookmark = reference.bookmark
            }
        }
        if let printFolder {
            settings.printFolder = printFolder
        }
        for index in nodes.indices {
            if let folder = outputFolders[nodes[index].id] {
                nodes[index].outputFolder = folder
            }
            if let folder = sourceFolders[nodes[index].id] {
                nodes[index].sourceFolder = folder
            }
        }
    }

    /// Where a Bake or Batch Bake node writes; nil returns it to the project's default folder.
    public mutating func setOutputFolder(_ folder: FileReference?, for node: NodeID) {
        guard let index = index(of: node), nodes[index].kind == .print || nodes[index].kind == .batchBake else { return }
        nodes[index].outputFolder = folder
    }

    /// The folder a Batch Audio node plays.
    public mutating func setSourceFolder(_ folder: FileReference?, for node: NodeID) {
        guard let index = index(of: node), nodes[index].kind == .batchAudio else { return }
        nodes[index].sourceFolder = folder
    }

    /// The project with every other output (Bake or Preview) removed, to render one path on its own.
    public func keepingOnlyOutput(_ node: NodeID) -> ProjectFile {
        var project = self
        project.removeNodes(Set(nodes.filter { $0.kind.isOutput && $0.id != node }.map(\.id)))
        return project
    }

    /// The project without Preview nodes — what Bake All renders.
    public func withoutPreviews() -> ProjectFile {
        var project = self
        project.removeNodes(Set(nodes.filter { $0.kind == .preview }.map(\.id)))
        return project
    }
}

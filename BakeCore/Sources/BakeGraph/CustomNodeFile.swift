import Foundation

public enum CustomNodeFileError: Error, Equatable {
    case unreadable
    case unsupportedFormat(Int)
    case unsupportedSchemaVersion(Int)
}

/// A `.bakenode` file (spec §12, Phase C): one custom node's definition and the audio files its
/// nodes play, so any document can use it. Pretty-printed, sorted-keys JSON, like `project.json`.
public struct CustomNodeFile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "bakenode"

    public var formatVersion: Int
    /// The schema the definition's nodes were saved at, so opening migrates them like a document.
    public var schemaVersion: Int
    public var definition: CustomNodeDefinition
    /// The audio files the definition's Audio nodes play.
    public var assets: [AssetReference]
    /// Optional, for people browsing a library; not needed to render.
    public var author: String?
    public var category: String?
    public var description: String?

    /// `definition` as `project` has it, with the files its Audio nodes use.
    public init(definition: CustomNodeDefinition, from project: ProjectFile) {
        formatVersion = Self.currentFormatVersion
        schemaVersion = ProjectFile.currentSchemaVersion
        self.definition = definition
        let used = Set(definition.nodes.compactMap(\.assetID))
        // A copy collected into this document isn't in the file, so another document finds the original.
        assets = project.assets.filter { used.contains($0.id) }.map { asset in
            var shared = asset
            shared.packagePath = nil
            return shared
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads a file, migrating its nodes as opening a document does. Newer formats and schemas fail
    /// clearly instead of half-loading.
    public static func decoded(_ data: Data) throws(CustomNodeFileError) -> CustomNodeFile {
        struct Probe: Decodable {
            let formatVersion: Int
            let schemaVersion: Int
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { throw .unreadable }
        guard probe.formatVersion <= currentFormatVersion else { throw .unsupportedFormat(probe.formatVersion) }
        guard probe.schemaVersion <= ProjectFile.currentSchemaVersion else { throw .unsupportedSchemaVersion(probe.schemaVersion) }
        guard var file = try? JSONDecoder().decode(CustomNodeFile.self, from: data) else { throw .unreadable }
        var nodes = ProjectFile(schemaVersion: probe.schemaVersion, nodes: file.definition.nodes)
        ProjectMigration.migrate(&nodes)
        file.definition.nodes = nodes.nodes
        file.schemaVersion = ProjectFile.currentSchemaVersion
        return file
    }
}

extension ProjectFile {
    /// Adds a file's definition and the audio files it uses; returns the definition's ID here. A
    /// document already holding that definition unchanged reuses it; one holding a different version
    /// under the same ID keeps both, the file's under a new ID.
    @discardableResult
    public mutating func importCustomNode(_ file: CustomNodeFile) -> UUID {
        let known = Set(assets.map(\.id))
        assets += file.assets.filter { !known.contains($0.id) }
        var definition = file.definition
        if let existing = customNodes.first(where: { $0.id == definition.id }) {
            if existing == definition { return existing.id }
            definition = CustomNodeDefinition(
                name: definition.name, version: definition.version, nodes: definition.nodes, edges: definition.edges
            )
        }
        customNodes.append(definition)
        return definition.id
    }
}

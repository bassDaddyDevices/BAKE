import Foundation

/// A user-chosen file or folder outside the package: its bookmark and the path it last had.
public struct FileReference: Hashable, Codable, Sendable {
    public var lastKnownPath: String
    public var bookmark: Data?

    public init(lastKnownPath: String, bookmark: Data? = nil) {
        self.lastKnownPath = lastKnownPath
        self.bookmark = bookmark
    }
}

/// Project-wide render settings.
public struct ProjectSettings: Hashable, Codable, Sendable {
    /// Every source is converted to this rate; all buffers run at it.
    public var sampleRate: Double
    /// Where Print nodes write (read/write bookmark). Files saved before M5 have none.
    public var printFolder: FileReference?

    public init(sampleRate: Double = 48_000, printFolder: FileReference? = nil) {
        self.sampleRate = sampleRate
        self.printFolder = printFolder
    }
}

/// A user-imported file. The bookmark is filled in by the app (M5); the compiler never reads files.
public struct AssetReference: Identifiable, Hashable, Codable, Sendable {
    public let id: AssetID
    public var lastKnownPath: String
    public var bookmark: Data?
    /// Collected into the document (schema 7): its copy inside the package, e.g. `Media/loop.wav`.
    /// Found there first, so the project keeps its sound wherever the package goes.
    public var packagePath: String?

    public init(id: AssetID = AssetID(), lastKnownPath: String, bookmark: Data? = nil, packagePath: String? = nil) {
        self.id = id
        self.lastKnownPath = lastKnownPath
        self.bookmark = bookmark
        self.packagePath = packagePath
    }
}

/// Root of a `.bake` package's `project.json`.
public struct ProjectFile: Codable, Equatable, Sendable {
    /// Bump on breaking format changes; older files are migrated forward on load.
    public static let currentSchemaVersion = 11

    public var schemaVersion: Int
    public var settings: ProjectSettings
    /// In creation order; the compiler uses this order to break ties.
    public var nodes: [Node]
    public var edges: [Edge]
    public var assets: [AssetReference]
    /// The definitions this document's custom nodes use (schema 5).
    public var customNodes: [CustomNodeDefinition]

    public init(
        schemaVersion: Int = ProjectFile.currentSchemaVersion,
        settings: ProjectSettings = ProjectSettings(),
        nodes: [Node] = [],
        edges: [Edge] = [],
        assets: [AssetReference] = [],
        customNodes: [CustomNodeDefinition] = []
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.nodes = nodes
        self.edges = edges
        self.assets = assets
        self.customNodes = customNodes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, settings, nodes, edges, assets, customNodes
    }

    /// Missing sections decode as empty so M0 files (schema version only) still open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        settings = try container.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? ProjectSettings()
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        edges = try container.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        assets = try container.decodeIfPresent([AssetReference].self, forKey: .assets) ?? []
        customNodes = try container.decodeIfPresent([CustomNodeDefinition].self, forKey: .customNodes) ?? []
    }

    /// The definition a custom node uses, if the document has it.
    public func definition(of node: Node) -> CustomNodeDefinition? {
        guard node.kind == .custom, let id = node.customDefinition else { return nil }
        return customNodes.first { $0.id == id }
    }
}

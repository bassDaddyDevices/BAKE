import Foundation

/// The patch that made a baked WAV, carried inside it. Every Bake node writes the whole project (not
/// the trimmed copy it rendered) and its own ID into a `bake` RIFF chunk at the end of the file;
/// players and DAWs skip chunks they don't know. Dropping the WAV on the canvas reopens the patch.
public struct BakedWorkflow: Codable, Equatable, Sendable {
    /// Bumped if this wrapper's shape changes; the project carries its own schema version.
    public static let currentVersion = 1
    /// The RIFF chunk ID.
    public static let chunkID = "bake"

    public var version: Int
    /// The Bake node that wrote the file.
    public var bakeNode: NodeID
    public var project: ProjectFile

    public init(bakeNode: NodeID, project: ProjectFile) {
        version = Self.currentVersion
        self.bakeNode = bakeNode
        self.project = project
    }

    // MARK: encoding

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a chunk's contents, migrating the project as opening a `.bake` does. Nil for anything
    /// that isn't a workflow this version of BAKE can read (unknown wrapper or a newer project schema).
    public static func decoded(_ data: Data) -> BakedWorkflow? {
        struct Probe: Decodable {
            struct Project: Decodable { let schemaVersion: Int }
            let version: Int
            let project: Project
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data),
              probe.version <= currentVersion, probe.project.schemaVersion <= ProjectFile.currentSchemaVersion,
              var workflow = try? JSONDecoder().decode(BakedWorkflow.self, from: data) else { return nil }
        ProjectMigration.migrate(&workflow.project)
        return workflow
    }

    // MARK: the WAV chunk

    /// Appends the workflow chunk to a finished RIFF/WAVE file and fixes the RIFF size. Files that
    /// aren't plain RIFF/WAVE (or would pass 4 GB) are left alone.
    public func append(toWAV url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else { return }
        let payload = try encoded()
        let end = try handle.seekToEnd()
        let padded = UInt64(payload.count + payload.count % 2)
        guard end + end % 2 + 8 + padded - 8 <= UInt64(UInt32.max) else { return }
        // RIFF chunks start on even offsets.
        var chunk = Data()
        if end % 2 == 1 { chunk.append(0) }
        chunk.append(Data(Self.chunkID.utf8))
        chunk.append(Self.littleEndian(UInt32(payload.count)))
        chunk.append(payload)
        if payload.count % 2 == 1 { chunk.append(0) }
        try handle.write(contentsOf: chunk)
        let riffSize = UInt32(try handle.seekToEnd() - 8)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.littleEndian(riffSize))
    }

    /// The workflow in a WAV file, or nil if it has none (or isn't one).
    public static func read(fromWAV url: URL) -> BakedWorkflow? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8),
              let length = try? handle.seekToEnd() else { return nil }
        var offset: UInt64 = 12
        while offset + 8 <= length {
            try? handle.seek(toOffset: offset)
            guard let chunkHeader = try? handle.read(upToCount: 8), chunkHeader.count == 8 else { return nil }
            let size = UInt64(chunkHeader.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
            if chunkHeader.prefix(4) == Data(chunkID.utf8) {
                guard offset + 8 + size <= length, let payload = try? handle.read(upToCount: Int(size)) else { return nil }
                return decoded(payload)
            }
            offset += 8 + size + size % 2
        }
        return nil
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

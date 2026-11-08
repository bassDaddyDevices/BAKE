import Foundation

/// A UUID tagged with what it identifies, so node and asset IDs can't be mixed up.
public struct Identifier<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}

public enum NodeTag {}
public enum AssetTag {}

public typealias NodeID = Identifier<NodeTag>
public typealias AssetID = Identifier<AssetTag>

/// Pin names: "in", "out", or "mod.<parameter>" for pins spawned from Page 2.
public typealias PinID = String
public typealias ParameterID = String

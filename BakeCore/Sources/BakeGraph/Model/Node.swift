import Foundation

/// Position on the canvas, in world coordinates.
public struct CanvasPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

/// One node on the canvas.
public struct Node: Identifiable, Hashable, Codable, Sendable {
    public let id: NodeID
    public var kind: NodeKind
    public var position: CanvasPoint
    /// Values the user has set. Parameters missing here use their catalog default.
    public var parameters: [ParameterID: ParameterValue]
    /// Parameters ticked on Page 2. Kept sorted and unique so saved files are stable.
    public private(set) var modulated: [ParameterID]
    /// Page 2 trim knob per modulated parameter, −1…+1. Missing entries mean +1.
    public private(set) var modulationTrims: [ParameterID: Double]
    /// Source file, for Audio nodes.
    public var assetID: AssetID?
    /// Bake (Print) and Batch Bake nodes: where this node writes; nil = the project's default folder.
    public var outputFolder: FileReference?
    /// Batch Audio nodes: the folder whose audio files they play.
    public var sourceFolder: FileReference?
    /// Custom nodes: which of the document's `customNodes` this one is.
    public var customDefinition: UUID?
    /// Inputs and Outputs inside a custom node: its pins, in the order the custom node shows them.
    public var ports: [CustomPort]?
    /// Parameters shown on the custom node this one sits in, as its own controls.
    public var promoted: [ParameterID]?

    public init(
        id: NodeID = NodeID(),
        kind: NodeKind,
        position: CanvasPoint = CanvasPoint(),
        parameters: [ParameterID: ParameterValue] = [:],
        modulated: [ParameterID] = [],
        modulationTrims: [ParameterID: Double] = [:],
        assetID: AssetID? = nil,
        outputFolder: FileReference? = nil,
        customDefinition: UUID? = nil,
        ports: [CustomPort]? = nil,
        promoted: [ParameterID]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.parameters = parameters
        self.modulated = Set(modulated).sorted()
        self.modulationTrims = modulationTrims.mapValues { min(max($0, -1), 1) }
        self.assetID = assetID
        self.outputFolder = outputFolder
        self.customDefinition = customDefinition
        self.ports = ports
        self.promoted = promoted
    }

    /// Sets a parameter's Page 2 trim, clamped to −1…+1.
    public mutating func setTrim(_ trim: Double, for parameter: ParameterID) {
        modulationTrims[parameter] = min(max(trim, -1), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, position, parameters, modulated, modulationTrims, assetID, outputFolder, sourceFolder, customDefinition, ports, promoted
    }

    /// Trims arrived in M3b and node folders in M5b; files saved before then decode without them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(NodeID.self, forKey: .id)
        kind = try container.decode(NodeKind.self, forKey: .kind)
        position = try container.decode(CanvasPoint.self, forKey: .position)
        parameters = try container.decode([ParameterID: ParameterValue].self, forKey: .parameters)
        modulated = try container.decode([ParameterID].self, forKey: .modulated)
        modulationTrims = try container.decodeIfPresent([ParameterID: Double].self, forKey: .modulationTrims) ?? [:]
        assetID = try container.decodeIfPresent(AssetID.self, forKey: .assetID)
        outputFolder = try container.decodeIfPresent(FileReference.self, forKey: .outputFolder)
        sourceFolder = try container.decodeIfPresent(FileReference.self, forKey: .sourceFolder)
        customDefinition = try container.decodeIfPresent(UUID.self, forKey: .customDefinition)
        ports = try container.decodeIfPresent([CustomPort].self, forKey: .ports)
        promoted = try container.decodeIfPresent([ParameterID].self, forKey: .promoted)
    }

    /// Ticks or unticks a parameter on Page 2.
    public mutating func setModulated(_ parameter: ParameterID, _ isModulated: Bool) {
        var set = Set(modulated)
        if isModulated {
            set.insert(parameter)
        } else {
            set.remove(parameter)
        }
        modulated = set.sorted()
    }
}

import Foundation
@testable import BakeGraph

/// Deterministic UUIDs so test graphs and their errors are reproducible.
func testUUID(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
}

let testAsset = AssetID(testUUID(9_000))

/// One second of 48 kHz stereo for `testAsset`.
let oneSecondStereo: [AssetID: AssetInfo] = [
    testAsset: AssetInfo(frameCount: 48_000, channelCount: 2, sampleRate: 48_000),
]

/// Builds test graphs. Nodes get sequential IDs in creation order; Audio nodes default to `testAsset`.
struct TestGraph {
    var project = ProjectFile()
    private var nextNumber = 1

    @discardableResult
    mutating func add(
        _ kind: NodeKind,
        _ parameters: [ParameterID: ParameterValue] = [:],
        modulated: [ParameterID] = [],
        asset: AssetID? = nil
    ) -> NodeID {
        let id = NodeID(testUUID(nextNumber))
        nextNumber += 1
        let assetID = asset ?? (kind == .audio ? testAsset : nil)
        project.nodes.append(Node(id: id, kind: kind, parameters: parameters, modulated: modulated, assetID: assetID))
        return id
    }

    mutating func connect(_ source: NodeID, _ sourcePin: PinID = "out", to target: NodeID, _ targetPin: PinID = "in") {
        project.edges.append(Edge(from: PinRef(node: source, pin: sourcePin), to: PinRef(node: target, pin: targetPin)))
    }
}

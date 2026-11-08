import Foundation
import Testing
@testable import BakeCanvas
@testable import BakeGraph

/// Writes the node catalog as JSON for the wiki's node pages (`Tools/wiki/node_pages.py`), only when
/// `BAKE_DUMP_CATALOG` names the file to write: `BAKE_DUMP_CATALOG=/tmp/bake-catalog.json swift test --filter CatalogDumpTests`.
struct CatalogDumpTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BAKE_DUMP_CATALOG"] != nil))
    func dump() throws {
        var nodes: [[String: Any]] = []
        for category in NodeCategory.allCases where category != .custom {
            let groups: [(String?, [NodeKind])] = category.subgroups.isEmpty
                ? [(nil, category.kinds)] : category.subgroups.map { ($0.title, $0.kinds) }
            for (subgroup, kinds) in groups {
                for kind in kinds {
                    let definition = NodeCatalog.definition(for: kind)
                    let node = Node(kind: kind, parameters: NodeCatalog.defaultParameters(for: kind))
                    let pins = NodeCatalog.pins(of: node).map { pin -> [String: Any] in
                        ["id": pin.id, "label": NodeCatalog.label(of: pin.id, on: node), "direction": pin.direction == .input ? "in" : "out",
                         "signal": pin.signal == .audio ? "audio" : "control", "required": pin.isRequired]
                    }
                    let parameters = definition.parameters.filter { $0.role != .hidden }.map { p -> [String: Any] in
                        var entry: [String: Any] = ["id": p.id, "name": p.name, "role": p.role == .macro ? "page1" : "page2",
                                                    "modulatable": p.isModulatable, "integer": p.isInteger]
                        if let condition = p.shownWhen {
                            entry["shownWhen"] = [
                                "parameter": condition.parameter, "values": condition.values.sorted(),
                                "titles": condition.values.sorted().map { ParameterFormat.title(forChoice: $0, of: condition.parameter) },
                            ]
                        }
                        switch p.kind {
                        case .number(let range, let value, let unit):
                            entry["type"] = "number"; entry["min"] = range.lowerBound; entry["max"] = range.upperBound
                            entry["default"] = value; entry["unit"] = unit
                        case .choice(let options, let value):
                            entry["type"] = "choice"
                            entry["options"] = options
                            entry["optionTitles"] = options.map { ParameterFormat.title(forChoice: $0, of: p.id) }
                            entry["default"] = value
                            entry["defaultTitle"] = ParameterFormat.title(forChoice: value, of: p.id)
                        case .text(let value):
                            entry["type"] = "text"; entry["default"] = value
                        }
                        return entry
                    }
                    var entry: [String: Any] = ["kind": kind.rawValue, "title": kind.title, "group": category.title, "pins": pins, "parameters": parameters]
                    if let subgroup { entry["subgroup"] = subgroup }
                    if let repeated = definition.repeated.first { entry["repeated"] = repeated.prefix }
                    nodes.append(entry)
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(filePath: try #require(ProcessInfo.processInfo.environment["BAKE_DUMP_CATALOG"])))
    }
}

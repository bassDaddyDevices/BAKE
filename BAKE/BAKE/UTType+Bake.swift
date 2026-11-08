import UniformTypeIdentifiers

extension UTType {
    /// A `.bake` project package. Declared under UTExportedTypeDeclarations in Info.plist.
    nonisolated static let bakeProject = UTType(exportedAs: "com.bassdaddydevices.bake", conformingTo: .package)
    /// A `.bakenode` custom node file (JSON). Declared under UTExportedTypeDeclarations in Info.plist.
    nonisolated static let bakeNode = UTType(exportedAs: "com.bassdaddydevices.bakenode", conformingTo: .json)
}

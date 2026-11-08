import BakeGraph
import BakeRender
import Foundation

extension GraphIssues {
    /// The problem behind a failed render, on the node that caused it when there is one.
    init(_ error: RenderError, in project: ProjectFile, files: ResolvedFiles) {
        self.init()
        switch error {
        case .unreadableAsset(let url):
            let readers = project.nodes.filter { node in node.assetID.flatMap { files.assetURLs[$0] } == url }
            if readers.isEmpty { addGeneral("Can't read “\(url.lastPathComponent)”.") }
            for node in readers {
                add("Can't read “\(url.lastPathComponent)” — is it a WAV, AIFF, or CAF file?", to: node.id)
            }
        case .missingAssetURL(let asset):
            for node in project.nodes where node.assetID == asset {
                add("Can't find this node's audio file — choose it again.", to: node.id)
            }
        case .unsupportedNode(let kind):
            addGeneral("\(kind.rawValue.capitalized) nodes can't be baked yet.")
        case .unsupportedModulation(let node):
            add("This modulation isn't supported yet.", to: node)
        case .gpuUnavailable:
            addGeneral("The Metal GPU engine couldn't start on this Mac.")
        case .insufficientMemory(let bytes):
            let gigabytes = (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)))
            addGeneral("This bake needs about \(gigabytes) GB of memory — use shorter sources or stretch less.")
        case .writeFailed(let url):
            addGeneral("Couldn't write “\(url.lastPathComponent)” — check its folder.")
        }
    }
}

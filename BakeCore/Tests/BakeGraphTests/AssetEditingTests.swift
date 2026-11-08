import Foundation
import Testing
@testable import BakeGraph

struct AssetEditingTests {
    @Test func assigningAudioCreatesOneAssetPerFile() throws {
        var project = ProjectFile()
        let a = project.addNode(.audio, at: CanvasPoint())
        let b = project.addNode(.audio, at: CanvasPoint())
        let first = project.assignAudio(path: "/x/kick.wav", bookmark: Data([1]), to: a)
        let second = project.assignAudio(path: "/x/kick.wav", bookmark: Data([2]), to: b)
        #expect(first != nil && first == second)
        #expect(project.assets.count == 1)
        #expect(project.assets.first?.bookmark == Data([2]))
        #expect(project.audioFileName(for: a) == "kick.wav")
    }

    @Test func onlyAudioNodesTakeFiles() {
        var project = ProjectFile()
        let filters = project.addNode(.filters, at: CanvasPoint())
        #expect(project.assignAudio(path: "/x/kick.wav", bookmark: nil, to: filters) == nil)
        #expect(project.assets.isEmpty)
    }

    @Test func replacedAndDeletedFilesLeaveNoUnusedAssets() {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        project.assignAudio(path: "/x/kick.wav", bookmark: nil, to: audio)
        project.assignAudio(path: "/x/snare.wav", bookmark: nil, to: audio)
        #expect(project.assets.map(\.lastKnownPath) == ["/x/snare.wav"])
        project.removeNodes([audio])
        #expect(project.assets.isEmpty)
    }

    @Test func refreshedReferencesReplaceOldOnes() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let assigned = project.assignAudio(path: "/old/kick.wav", bookmark: Data([1]), to: audio)
        let asset = try #require(assigned)
        project.updateFileReferences(
            assets: [asset: FileReference(lastKnownPath: "/new/kick.wav", bookmark: Data([9]))],
            printFolder: FileReference(lastKnownPath: "/out", bookmark: Data([7]))
        )
        #expect(project.assets.first?.lastKnownPath == "/new/kick.wav")
        #expect(project.assets.first?.bookmark == Data([9]))
        #expect(project.settings.printFolder == FileReference(lastKnownPath: "/out", bookmark: Data([7])))
    }

    @Test func printFolderRoundTripsAndOldFilesStillOpen() throws {
        var project = ProjectFile()
        project.settings.printFolder = FileReference(lastKnownPath: "/out", bookmark: Data([1, 2]))
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(project))
        #expect(decoded.settings.printFolder == project.settings.printFolder)

        let old = Data(#"{"schemaVersion":1,"settings":{"sampleRate":48000}}"#.utf8)
        #expect(try JSONDecoder().decode(ProjectFile.self, from: old).settings.printFolder == nil)
    }
}

struct BakeNodeEditingTests {
    private let folder = FileReference(lastKnownPath: "/x/bounces", bookmark: Data([7]))

    @Test func onlyBakeNodesTakeAFolder() {
        var project = ProjectFile()
        let bake = project.addNode(.print, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        project.setOutputFolder(folder, for: bake)
        project.setOutputFolder(folder, for: filters)
        #expect(project.node(bake)?.outputFolder == folder)
        #expect(project.node(filters)?.outputFolder == nil)
        project.setOutputFolder(nil, for: bake)
        #expect(project.node(bake)?.outputFolder == nil)
    }

    @Test func keepingOneOutputKeepsItsPath() throws {
        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let first = project.addNode(.print, at: CanvasPoint())
        let second = project.addNode(.print, at: CanvasPoint())
        let preview = project.addNode(.preview, at: CanvasPoint())
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: first, pin: "in"))
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: second, pin: "in"))
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: preview, pin: "in"))

        let only = project.keepingOnlyOutput(first)

        #expect(Set(only.nodes.map(\.id)) == [audio, first])
        #expect(only.edges.count == 1)
    }

    @Test func bakeAllLeavesPreviewsOut() {
        var project = ProjectFile()
        project.addNode(.print, at: CanvasPoint())
        project.addNode(.preview, at: CanvasPoint())
        #expect(project.withoutPreviews().nodes.map(\.kind) == [.print])
    }

    @Test func refreshedNodeFoldersAreStored() {
        var project = ProjectFile()
        let bake = project.addNode(.print, at: CanvasPoint())
        project.setOutputFolder(FileReference(lastKnownPath: "/old"), for: bake)
        project.updateFileReferences(assets: [:], printFolder: nil, outputFolders: [bake: folder])
        #expect(project.node(bake)?.outputFolder == folder)
    }

    @Test func nodeFoldersSaveAndOlderNodesStillOpen() throws {
        var project = ProjectFile()
        let bake = project.addNode(.print, at: CanvasPoint())
        project.setOutputFolder(folder, for: bake)
        let reopened = try ProjectPackage.project(from: ProjectPackage.fileWrapper(for: project))
        #expect(reopened.node(bake)?.outputFolder == folder)

        let old = Data(#"{"id":"\#(UUID().uuidString)","kind":"print","position":{"x":0,"y":0},"parameters":{},"modulated":[]}"#.utf8)
        #expect(try JSONDecoder().decode(Node.self, from: old).outputFolder == nil)
    }

    @Test func newBakesSaveVersionsByDefault() {
        #expect(NodeCatalog.defaultParameters(for: .print)["versions"] == .choice("newVersion"))
    }
}

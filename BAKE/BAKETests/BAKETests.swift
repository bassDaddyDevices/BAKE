import AVFAudio
import BakeGraph
import BakeSession
import Foundation
import Security
import Testing
import UniformTypeIdentifiers
@testable import BAKE

struct SecurityScopedBookmarkTests {
    /// Runs inside the sandboxed test host, so this exercises the real bookmark path.
    @Test func bookmarksRoundTripInTheSandbox() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bake-bookmark-\(UUID().uuidString).txt")
        try Data("bake".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let access = SecurityScopedFileAccess()

        let resolved = try access.resolve(access.bookmark(for: url, writable: false))

        #expect(resolved.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
    }

    /// Product-owner report: bake, change the patch, bake again — a new version with the new sound.
    @MainActor
    @Test func reBakingInTheSandboxSavesANewVersion() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bake-rebake-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        for frame in 0..<24_000 { buffer.floatChannelData?[0][frame] = sin(Float(frame) * 0.05) * 0.5 }
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        let access = SecurityScopedFileAccess()

        var project = ProjectFile()
        let audio = project.addNode(.audio, at: CanvasPoint())
        let filters = project.addNode(.filters, at: CanvasPoint())
        let print = project.addNode(.print, at: CanvasPoint())
        project.assignAudio(path: source.path(percentEncoded: false), bookmark: try access.bookmark(for: source, writable: false), to: audio)
        try project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: filters, pin: "in"))
        try project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: print, pin: "in"))
        project.settings.printFolder = FileReference(lastKnownPath: folder.path(percentEncoded: false), bookmark: try access.bookmark(for: folder, writable: true))
        let session = BakeSession(access: access)

        session.bake(project)
        await session.waitUntilFinished()
        guard case .finished(let first) = session.state else { Issue.record("expected finished, got \(session.state)"); return }
        let firstFile = try #require(first.first)
        let before = try Data(contentsOf: firstFile)

        project.setParameter("cutoff", of: filters, to: .number(200))
        session.projectDidChange()
        session.bake(project)
        await session.waitUntilFinished()
        guard case .finished(let second) = session.state else { Issue.record("expected finished, got \(session.state)"); return }

        let secondFile = try #require(second.first)
        #expect(secondFile.lastPathComponent == "bake-2.wav")
        #expect(try Data(contentsOf: secondFile) != before)
        #expect(try Data(contentsOf: firstFile) == before)
    }
}

struct BakeDocumentTypeTests {
    @Test func bakeProjectIsAPackage() {
        #expect(UTType.bakeProject.identifier == "com.bassdaddydevices.bake")
        #expect(UTType.bakeProject.conforms(to: .package))
    }

    @Test func bakeExtensionIsRegistered() {
        // Only true if the Info.plist export declaration is present.
        #expect(UTType.bakeProject.preferredFilenameExtension == "bake")
        // Packages are directories, not `public.data`, so the lookup must name the supertype.
        #expect(UTType(filenameExtension: "bake", conformingTo: .package) == .bakeProject)
    }

    @Test func documentReadsOnlyBakeProjects() {
        #expect(BakeDocument.readableContentTypes == [.bakeProject])
    }
}

struct SandboxEntitlementTests {
    /// Reads a boolean entitlement from the running (test host) app's code signature.
    private func entitlement(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
            return false
        }
        return (value as? Bool) ?? false
    }

    @Test func appIsSandboxed() {
        #expect(entitlement("com.apple.security.app-sandbox"))
    }

    @Test func userSelectedFilesAreReadWrite() {
        // Without read/write, NSSavePanel refuses to open and Save hangs the document window.
        #expect(entitlement("com.apple.security.files.user-selected.read-write"))
    }
}

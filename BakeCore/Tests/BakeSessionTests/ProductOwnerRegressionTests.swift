import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

private let regressionFolder = URL(filePath: "/tmp/skrillex", directoryHint: .isDirectory)

/// Saved documents must never change sound. Opt-in: prepare `/tmp/skrillex/` with a copy of a real
/// document (`bake.bake`, its paths pointed at `source.wav` and `out/`, bookmarks removed), the
/// source audio, and the file it baked to (`reference.wav`). Skipped when that folder is absent.
@MainActor
struct ProductOwnerRegressionTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: regressionFolder.appending(path: "bake.bake").path(percentEncoded: false))))
    func savedDocumentReBakesToTheSameAudio() async throws {
        let output = regressionFolder.appending(path: "out", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let project = try ProjectPackage.project(from: FileWrapper(url: regressionFolder.appending(path: "bake.bake")))
        let session = BakeSession(access: PlainFileAccess())

        session.bake(project)
        await session.waitUntilFinished()

        guard case .finished(let outputs) = session.state else { Issue.record("expected finished, got \(session.state)"); return }
        let baked = try #require(outputs.first)
        // Sample for sample: bakes now also carry their patch, which an older reference doesn't.
        #expect(try samples(baked) == samples(regressionFolder.appending(path: "reference.wav")))
    }
}

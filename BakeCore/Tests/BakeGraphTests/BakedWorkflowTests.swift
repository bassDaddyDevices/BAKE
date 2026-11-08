import Foundation
import Testing
@testable import BakeGraph

struct BakedWorkflowTests {
    /// A minimal RIFF/WAVE file: fmt and data chunks, with an odd-length data chunk to test padding.
    private func wav(dataBytes: Int = 5) -> Data {
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var body = Data("WAVE".utf8)
        body += Data("fmt ".utf8) + le32(16) + Data(repeating: 1, count: 16)
        body += Data("data".utf8) + le32(UInt32(dataBytes)) + Data(repeating: 7, count: dataBytes)
        if dataBytes % 2 == 1 { body.append(0) }
        return Data("RIFF".utf8) + le32(UInt32(body.count)) + body
    }

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private func project() -> (ProjectFile, NodeID) {
        var project = ProjectFile()
        _ = project.addNode(.filters, at: CanvasPoint())
        let bake = project.addNode(.print, at: CanvasPoint(x: 400, y: 0))
        project.setParameter("cutoff", of: project.nodes[0].id, to: .number(2_345))
        return (project, bake)
    }

    @Test func aWorkflowRoundTripsThroughAWAV() throws {
        let original = wav()
        let url = try file(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, bake) = project()
        try BakedWorkflow(bakeNode: bake, project: project).append(toWAV: url)

        let read = try #require(BakedWorkflow.read(fromWAV: url))
        #expect(read.bakeNode == bake && read.project == project)
        // The original bytes are untouched; only the RIFF size grew, to the file's length minus 8.
        let written = try Data(contentsOf: url)
        #expect(written.count % 2 == 0)
        #expect(written[8..<original.count] == original[8...])
        let size = written[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        #expect(Int(size) == written.count - 8)
    }

    @Test func plainAndBrokenFilesHaveNoWorkflow() throws {
        let plain = try file(wav())
        let garbage = try file(Data("not a wav at all".utf8))
        let truncated = try file(wav().prefix(30))
        defer { [plain, garbage, truncated].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(BakedWorkflow.read(fromWAV: plain) == nil)
        #expect(BakedWorkflow.read(fromWAV: garbage) == nil)
        #expect(BakedWorkflow.read(fromWAV: truncated) == nil)
        // Appending to a non-WAV does nothing.
        let (project, bake) = project()
        try BakedWorkflow(bakeNode: bake, project: project).append(toWAV: garbage)
        #expect(try Data(contentsOf: garbage) == Data("not a wav at all".utf8))
    }

    @Test func newerWorkflowsAreNotReadAndOlderOnesMigrate() throws {
        let (project, bake) = project()
        let data = try BakedWorkflow(bakeNode: bake, project: project).encoded()
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = BakedWorkflow.currentVersion + 1
        #expect(BakedWorkflow.decoded(try JSONSerialization.data(withJSONObject: json)) == nil)
        var newer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var inner = try #require(newer["project"] as? [String: Any])
        inner["schemaVersion"] = ProjectFile.currentSchemaVersion + 1
        newer["project"] = inner
        #expect(BakedWorkflow.decoded(try JSONSerialization.data(withJSONObject: newer)) == nil)
        #expect(BakedWorkflow.decoded(data)?.project == project)
    }
}

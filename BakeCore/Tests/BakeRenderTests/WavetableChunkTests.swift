import Foundation
import Testing
@testable import BakeGraph
@testable import BakeRender

struct WavetableChunkTests {
    private func wav(dataBytes: Int = 5) -> Data {
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var body = Data("WAVE".utf8)
        body += Data("fmt ".utf8) + le32(16) + Data(repeating: 1, count: 16)
        body += Data("data".utf8) + le32(UInt32(dataBytes)) + Data(repeating: 7, count: dataBytes)
        if dataBytes % 2 == 1 { body.append(0) }
        return Data("RIFF".utf8) + le32(UInt32(body.count)) + body
    }

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WavetableChunk-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private func chunks(in data: Data) -> [(id: String, payload: Data)] {
        guard data.count >= 12 else { return [] }
        var result: [(String, Data)] = []
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = data[(offset + 4)..<(offset + 8)].enumerated().reduce(UInt32(0)) {
                $0 | UInt32($1.element) << (8 * UInt32($1.offset))
            }
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(size)
            guard payloadEnd <= data.count else { break }
            result.append((id, data[payloadStart..<payloadEnd]))
            offset = payloadEnd + Int(size % 2)
        }
        return result
    }

    @Test func appendsClmChunkWithCorrectPayloadPaddingAndRiffSize() throws {
        for frameSize in [256, 2048] {
            let original = wav()
            let url = try file(original)
            defer { try? FileManager.default.removeItem(at: url) }

            try WavetableChunk.append(toWAV: url, frameSize: frameSize)

            let written = try Data(contentsOf: url)
            let parsed = chunks(in: written)
            let clm = try #require(parsed.first { $0.id == "clm " })
            let payload = "<!>\(frameSize) 10000000 wavetable (bake)"
            #expect(clm.payload == Data(payload.utf8))
            #expect(written.count % 2 == 0)
            #expect(written[8..<original.count] == original[8...])
            let riffSize = written[4..<8].enumerated().reduce(UInt32(0)) {
                $0 | UInt32($1.element) << (8 * UInt32($1.offset))
            }
            #expect(Int(riffSize) == written.count - 8)
        }
    }

    @Test func clmChunkPrecedesWorkflowAndAudioRemainsIntact() throws {
        let original = wav(dataBytes: 8)
        let url = try file(original)
        defer { try? FileManager.default.removeItem(at: url) }
        var project = ProjectFile()
        let bake = project.addNode(.print, at: CanvasPoint())

        try WavetableChunk.append(toWAV: url, frameSize: 2048)
        try BakedWorkflow(bakeNode: bake, project: project).append(toWAV: url)

        let written = try Data(contentsOf: url)
        let parsed = chunks(in: written)
        #expect(parsed.map(\.id).suffix(2) == ["clm ", "bake"])
        #expect(try #require(BakedWorkflow.read(fromWAV: url)).bakeNode == bake)
        #expect(written[8..<original.count] == original[8...])
        let riffSize = written[4..<8].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << (8 * UInt32($1.offset))
        }
        #expect(Int(riffSize) == written.count - 8)
    }

    @Test func nonWavFilesAreLeftUnchanged() throws {
        let original = Data("not wav".utf8)
        let url = try file(original)
        defer { try? FileManager.default.removeItem(at: url) }
        try WavetableChunk.append(toWAV: url, frameSize: 2048)
        #expect(try Data(contentsOf: url) == original)
    }
}

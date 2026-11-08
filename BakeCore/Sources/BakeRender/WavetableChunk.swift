import Foundation

/// Optional wavetable metadata for synths that recognize the `clm ` RIFF chunk.
enum WavetableChunk {
    static func append(toWAV url: URL, frameSize: Int) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else { return }

        let payload = Data("<!>\(frameSize) 10000000 wavetable (bake)".utf8)
        let end = try handle.seekToEnd()
        let paddedPayloadCount = payload.count + payload.count % 2
        let requiredBytes = (end % 2) + 8 + UInt64(paddedPayloadCount)
        guard end + requiredBytes - 8 <= UInt64(UInt32.max) else { return }

        var chunk = Data()
        if end % 2 == 1 { chunk.append(0) }
        chunk.append(Data("clm ".utf8))
        chunk.append(littleEndian(UInt32(payload.count)))
        chunk.append(payload)
        if payload.count % 2 == 1 { chunk.append(0) }
        try handle.write(contentsOf: chunk)

        let riffSize = try handle.seekToEnd() - 8
        guard riffSize <= UInt64(UInt32.max) else { return }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndian(UInt32(riffSize)))
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

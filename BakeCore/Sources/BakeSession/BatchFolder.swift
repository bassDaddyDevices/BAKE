import BakeGraph
import CryptoKit
import Foundation

/// The audio files a Batch Audio node plays: the folder's own files (not its subfolders), filtered
/// and ordered by the node's settings. The same folder and settings give the same order on any Mac.
public enum BatchFolder {
    public static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "flac"]

    /// `info` reads a file's header; it's asked only when Project Rate Only or Duration needs it.
    public static func files(
        in folder: URL, parameters: [ParameterID: ParameterValue], sampleRate: Double, info: (URL) -> AssetInfo?
    ) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        var files = contents.filter { url in
            audioExtensions.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        switch parameters["formats"] {
        case .choice("wav")?: files = files.filter { ["wav", "wave"].contains($0.pathExtension.lowercased()) }
        case .choice("matchRate")?: files = files.filter { info($0)?.sampleRate == sampleRate }
        default: break
        }
        // Finder's order: "2.wav" before "10.wav".
        let byName = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        switch parameters["order"] {
        case .choice("duration")?:
            return sorted(byName) { info($0).map { Double($0.frameCount) / $0.sampleRate } ?? 0 }
        case .choice("size")?:
            return sorted(byName) { Double((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        case .choice("random")?:
            let seed = Int(parameters["seed"]?.numberValue ?? 1)
            return sorted(byName) { hash(seed: seed, name: $0.lastPathComponent) }
        default:
            return byName
        }
    }

    /// Sorted by `key`, keeping name order between equal keys.
    private static func sorted<Key: Comparable>(_ files: [URL], by key: (URL) -> Key) -> [URL] {
        files.enumerated()
            .map { (key: key($0.element), index: $0.offset, url: $0.element) }
            .sorted { ($0.key, $0.index) < ($1.key, $1.index) }
            .map(\.url)
    }

    /// The first 8 bytes of SHA-256(seed ‖ name): a shuffle that depends only on the names and the seed.
    private static func hash(seed: Int, name: String) -> UInt64 {
        var bytes = Data()
        withUnsafeBytes(of: Int64(seed).littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(Data(name.utf8))
        return SHA256.hash(data: bytes).prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }
}

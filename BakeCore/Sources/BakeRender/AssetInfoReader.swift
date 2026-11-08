import AVFAudio
import BakeGraph
import Foundation

/// Reads the metadata the compiler needs from audio files.
public enum AssetInfoReader {
    public static func info(for url: URL) throws(RenderError) -> AssetInfo {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.fileFormat
            return AssetInfo(
                frameCount: Int(file.length),
                channelCount: Int(format.channelCount),
                sampleRate: format.sampleRate
            )
        } catch {
            throw .unreadableAsset(url)
        }
    }

    public static func infos(for urls: [AssetID: URL]) throws(RenderError) -> [AssetID: AssetInfo] {
        var infos: [AssetID: AssetInfo] = [:]
        for (id, url) in urls {
            infos[id] = try info(for: url)
        }
        return infos
    }
}

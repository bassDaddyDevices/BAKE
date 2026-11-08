import AudioToolbox
import AVFAudio
import BakeGraph
import Foundation
import Observation

/// Plays one preview at a time, through `outputDeviceUID`'s device (or the system default when it is
/// empty or not connected). Starting another stops the first.
@MainActor @Observable
public final class PreviewPlayer {
    public private(set) var playingNode: NodeID?
    /// Settings › Output device. Read when a preview starts.
    public var outputDeviceUID = ""
    /// The device the last preview was routed to; nil for the system default.
    public private(set) var routedDevice: AudioDeviceID?
    private var engine: AVAudioEngine?
    private var playback = 0

    public init() {}

    public func play(_ url: URL, for node: NodeID) {
        stop()
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        routedDevice = outputDeviceUID.isEmpty ? nil : AudioOutputDevices.deviceID(forUID: outputDeviceUID)
        if var device = routedDevice, let unit = engine.outputNode.audioUnit {
            // A device that refuses leaves the default in place.
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr { routedDevice = nil }
        }
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        playback += 1
        let current = playback
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playback == current else { return }
                self.stop()
            }
        }
        do {
            try engine.start()
        } catch {
            return
        }
        player.play()
        self.engine = engine
        playingNode = node
    }

    public func stop() {
        playback += 1
        engine?.stop()
        engine = nil
        playingNode = nil
    }
}

import AVFAudio
import BakeGraph
import Foundation
import Testing
@testable import BakeSession

struct AppPreferencesTests {
    private func defaults() -> UserDefaults {
        let name = "bake.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func newDocumentsStartWithTheDefaultFolder() {
        let defaults = defaults()
        #expect(AppPreferences.newProject(defaults: defaults).settings.printFolder == nil)
        let folder = FileReference(lastKnownPath: "/Users/someone/Bakes", bookmark: Data([1, 2, 3]))
        AppPreferences.setDefaultFolder(folder, in: defaults)
        #expect(AppPreferences.defaultFolder(in: defaults) == folder)
        #expect(AppPreferences.newProject(defaults: defaults).settings.printFolder == folder)
        AppPreferences.setDefaultFolder(nil, in: defaults)
        #expect(AppPreferences.newProject(defaults: defaults).settings.printFolder == nil)
    }

    @Test func settingsStartOn() {
        let defaults = defaults()
        defaults.register(defaults: AppPreferences.registered)
        #expect(defaults.bool(forKey: AppPreferences.animateCardsKey))
        #expect(defaults.bool(forKey: AppPreferences.embedWorkflowKey))
        #expect(defaults.string(forKey: AppPreferences.outputDeviceKey) == "")
    }

    @Test func everyListedOutputCanBeFoundByItsUID() {
        // Whatever this Mac has (a CI machine may have none): each listed device resolves back.
        for device in AudioOutputDevices.list() {
            #expect(!device.uid.isEmpty && !device.name.isEmpty)
            #expect(AudioOutputDevices.deviceID(forUID: device.uid) != nil, "\(device.name)")
        }
        #expect(AudioOutputDevices.deviceID(forUID: "no such device") == nil)
    }

    @MainActor
    @Test func previewsFallBackToTheDefaultOutput() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Silence, so running the tests never makes a sound.
        let url = folder.appending(path: "silence.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        silence.frameLength = 4_800
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: silence)
        let player = PreviewPlayer()
        player.outputDeviceUID = "no such device"
        player.play(url, for: NodeID())
        #expect(player.routedDevice == nil)              // unknown device: the system default plays it
        if let device = AudioOutputDevices.list().first {
            player.outputDeviceUID = device.uid
            player.play(url, for: NodeID())
            #expect(player.routedDevice == AudioOutputDevices.deviceID(forUID: device.uid))
        }
        player.stop()
        #expect(player.playingNode == nil)
    }
}

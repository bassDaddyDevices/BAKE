import BakeGraph
import BakeSession
import SwiftUI
import UniformTypeIdentifiers

/// BAKE › Settings (⌘,): choices that apply to every document.
struct SettingsView: View {
    @AppStorage(AppPreferences.outputDeviceKey) private var outputDevice = ""
    @AppStorage(AppPreferences.animateCardsKey) private var animateCards = true
    @AppStorage(AppPreferences.embedWorkflowKey) private var embedWorkflow = true
    @State private var devices: [AudioOutputDevice] = []
    @State private var defaultFolder = AppPreferences.defaultFolder()
    @State private var isPickingFolder = false
    @State private var folderProblem: String?
    @State private var wordListsFolder = AppPreferences.wordListsFolder()
    @State private var isPickingWordLists = false
    @State private var wordListsProblem: String?

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Output device", selection: $outputDevice) {
                    Text("System Default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // A chosen device that is unplugged stays listed, so the choice isn't lost.
                    if !outputDevice.isEmpty, !devices.contains(where: { $0.uid == outputDevice }) {
                        Text("Disconnected device").tag(outputDevice)
                    }
                }
                .accessibilityIdentifier("settings.outputDevice")
                Text("Preview plays through this device. Bakes are files, so they don't depend on it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Canvas") {
                Toggle("Animate card pictures", isOn: $animateCards)
                    .accessibilityIdentifier("settings.animateCards")
                Text("Off holds the moving pictures (LFO, Envelope, Phaser…) still, to save CPU and GPU on big patches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Bakes") {
                Toggle("Embed the patch in baked files", isOn: $embedWorkflow)
                    .accessibilityIdentifier("settings.embedWorkflow")
                Text("Lets you drop a baked WAV on the canvas to reopen its patch. The file then also holds your source files' names and folders; turn this off for files you share.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("New documents") {
                LabeledContent("Default Bake folder") {
                    HStack {
                        Text(defaultFolder.map { URL(filePath: $0.lastKnownPath).lastPathComponent } ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Choose…") { isPickingFolder = true }
                        if defaultFolder != nil {
                            Button("Clear") {
                                defaultFolder = nil
                                AppPreferences.setDefaultFolder(nil)
                            }
                        }
                    }
                }
                Text("New documents start with this folder for their Bake nodes. Documents you already have keep their own.")
                    .font(.caption).foregroundStyle(.secondary)
                if let folderProblem {
                    Text(folderProblem).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Random names") {
                LabeledContent("Word lists") {
                    HStack {
                        Text(wordListsFolder.map { URL(filePath: $0.lastKnownPath).lastPathComponent } ?? "Built-in")
                            .foregroundStyle(.secondary)
                        Button("Choose…") { isPickingWordLists = true }
                        if wordListsFolder != nil {
                            Button("Use Built-in") {
                                wordListsFolder = nil
                                AppPreferences.setWordListsFolder(nil)
                            }
                        }
                    }
                }
                Text("Batch Bake's Random Words names are Adjective_Prefix_Suffix. Choose a folder holding adjectives.txt, prefixes.txt and suffixes.txt (one word per line) to use your own words.")
                    .font(.caption).foregroundStyle(.secondary)
                if let wordListsProblem {
                    Text(wordListsProblem).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { devices = AudioOutputDevices.list() }
        // A second picker on a separate view: SwiftUI ignores a second `fileImporter` on the same one.
        .background {
            Color.clear.fileImporter(isPresented: $isPickingWordLists, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                let started = url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }
                guard let lists = AppPreferences.readWordLists(in: url) else {
                    wordListsProblem = "“\(url.lastPathComponent)” needs adjectives.txt, prefixes.txt and suffixes.txt, each with at least one word."
                    return
                }
                do {
                    let bookmark = try SecurityScopedFileAccess().bookmark(for: url, writable: false)
                    let folder = FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: bookmark)
                    AppPreferences.setWordListsFolder(folder)
                    wordListsFolder = folder
                    wordListsProblem = nil
                    _ = lists
                } catch {
                    wordListsProblem = "macOS wouldn't let BAKE keep access to “\(url.lastPathComponent)”."
                }
            }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                let bookmark = try SecurityScopedFileAccess().bookmark(for: url, writable: true)
                let folder = FileReference(lastKnownPath: url.path(percentEncoded: false), bookmark: bookmark)
                AppPreferences.setDefaultFolder(folder)
                defaultFolder = folder
                folderProblem = nil
            } catch {
                folderProblem = "macOS wouldn't let BAKE keep access to “\(url.lastPathComponent)”."
            }
        }
    }
}

#Preview {
    SettingsView()
}

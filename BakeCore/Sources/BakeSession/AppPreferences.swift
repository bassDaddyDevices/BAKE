import BakeGraph
import Foundation

/// BAKE › Settings: app-wide choices, kept in `UserDefaults`. Documents never store these.
public enum AppPreferences {
    /// The output device's Core Audio UID for Preview; empty plays through the system default.
    public static let outputDeviceKey = "outputDeviceUID"
    /// Whether card pictures move. Default on.
    public static let animateCardsKey = "animateCardPictures"
    /// Whether baked WAVs carry their patch (roadmap #27). Default on.
    public static let embedWorkflowKey = "embedWorkflowInBakes"
    /// The default Bake folder new documents start with: an encoded `FileReference`.
    public static let defaultFolderKey = "defaultFolderForNewDocuments"
    /// A folder of word lists for Random Words names (`adjectives.txt`, `prefixes.txt`, `suffixes.txt`):
    /// an encoded `FileReference`. Unset uses BAKE's own lists.
    public static let wordListsFolderKey = "randomNameWordListsFolder"

    /// The settings' starting values, for `UserDefaults.register(defaults:)`.
    public static var registered: [String: Any] {
        [outputDeviceKey: "", animateCardsKey: true, embedWorkflowKey: true]
    }

    public static func defaultFolder(in defaults: UserDefaults = .standard) -> FileReference? {
        defaults.data(forKey: defaultFolderKey).flatMap { try? JSONDecoder().decode(FileReference.self, from: $0) }
    }

    public static func setDefaultFolder(_ folder: FileReference?, in defaults: UserDefaults = .standard) {
        if let folder, let data = try? JSONEncoder().encode(folder) {
            defaults.set(data, forKey: defaultFolderKey)
        } else {
            defaults.removeObject(forKey: defaultFolderKey)
        }
    }

    public static func wordListsFolder(in defaults: UserDefaults = .standard) -> FileReference? {
        defaults.data(forKey: wordListsFolderKey).flatMap { try? JSONDecoder().decode(FileReference.self, from: $0) }
    }

    public static func setWordListsFolder(_ folder: FileReference?, in defaults: UserDefaults = .standard) {
        if let folder, let data = try? JSONEncoder().encode(folder) {
            defaults.set(data, forKey: wordListsFolderKey)
        } else {
            defaults.removeObject(forKey: wordListsFolderKey)
        }
    }

    /// The word lists Random Words names use: the chosen folder's, or BAKE's own when none is chosen or
    /// it can't be read.
    public static func wordLists(access: any FileAccess = SecurityScopedFileAccess(), in defaults: UserDefaults = .standard) -> WordLists {
        guard let folder = wordListsFolder(in: defaults) else { return .builtIn }
        var url = URL(filePath: folder.lastKnownPath)
        if let bookmark = folder.bookmark, let resolved = try? access.resolve(bookmark) { url = resolved.url }
        return readWordLists(in: url, access: access) ?? .builtIn
    }

    /// The three lists in a folder, or nil when one is missing or empty.
    public static func readWordLists(in folder: URL, access: any FileAccess = SecurityScopedFileAccess()) -> WordLists? {
        let started = access.startAccessing(folder)
        defer { if started { access.stopAccessing(folder) } }
        func read(_ name: String) -> String? { try? String(contentsOf: folder.appending(path: name), encoding: .utf8) }
        guard let adjectives = read("adjectives.txt"), let prefixes = read("prefixes.txt"), let suffixes = read("suffixes.txt") else {
            return nil
        }
        return WordLists(adjectives: adjectives, prefixes: prefixes, suffixes: suffixes)
    }

    /// An empty project for File › New: it starts with the default folder, if one is set.
    public static func newProject(defaults: UserDefaults = .standard) -> ProjectFile {
        var project = ProjectFile()
        project.settings.printFolder = defaultFolder(in: defaults)
        return project
    }
}

import BakeCanvas
import BakeSession
import SwiftUI

@main
struct BAKEApp: App {
    init() {
        UserDefaults.standard.register(defaults: AppPreferences.registered)
    }

    var body: some Scene {
        // New documents start with Settings' default Bake folder (the argument is evaluated for each new document).
        DocumentGroup(newDocument: BakeDocument(project: AppPreferences.newProject())) { file in
            ContentView(document: file.$document)
        }
        .commands { CanvasCommands() }
        Settings {
            SettingsView()
        }
    }
}

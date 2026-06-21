import SwiftUI

/// Menu-bar accessory application (spec §3, §12). `LSUIElement` is set in
/// Info.plist so there is no Dock icon or main window — only the menu-bar item
/// and the Settings scene.
@main
struct TeamsDeEsserApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Teams De-Esser", systemImage: "waveform.badge.mic") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

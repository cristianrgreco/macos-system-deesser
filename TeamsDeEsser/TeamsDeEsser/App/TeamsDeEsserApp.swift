import SwiftUI

/// Menu-bar accessory application (spec §3, §12). `LSUIElement` is set in
/// Info.plist so there is no Dock icon or main window — only the menu-bar item
/// and the Settings scene.
@main
struct TeamsDeEsserApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // Plain waveform when idle; same waveform with a small check badge
            // once processing is enabled, so the menu bar shows at a glance
            // whether de-essing is active without changing the glyph's size.
            Image(systemName: model.enabled ? "waveform.badge.checkmark" : "waveform")
                .accessibilityLabel("Teams De-Esser")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

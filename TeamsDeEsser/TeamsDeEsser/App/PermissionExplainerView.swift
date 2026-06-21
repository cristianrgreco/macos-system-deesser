import SwiftUI

/// Pre-flight explanation shown on the first explicit enable (spec §12.3). There
/// is no private permission preflight; acknowledging this attempts tap creation,
/// which lets macOS present the system-audio recording prompt.
struct PermissionExplainerView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Allow Teams audio processing")
                    .font(.title3).bold()
            }

            Text("""
            macOS will ask for permission to record this Mac's system audio. \
            Teams De-Esser only reads Microsoft Teams playback so it can reduce \
            harsh sibilance.
            """)

            Label("Audio is processed live on this Mac.", systemImage: "lock.shield")
                .font(.callout)
            Label("Nothing is recorded, saved, or sent anywhere.", systemImage: "externaldrive.badge.xmark")
                .font(.callout)
            Label("Your microphone and other apps are untouched.", systemImage: "mic.slash")
                .font(.callout)

            if case .recoverableError(let error) = model.state, error.suggestsPrivacySettings {
                Divider()
                Text("Permission appears to be denied. Enable Teams De-Esser under Privacy & Security ▸ System Audio Recording.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Privacy & Security") { model.openPrivacySettings() }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.cancelEnable() }
                Button("Continue") { model.confirmEnable() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

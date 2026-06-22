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
                Text("Allow system-wide audio processing")
                    .font(.title3).bold()
            }

            Text("""
            macOS will ask for permission to record this Mac's system audio. \
            De-Esser reads the audio your apps play so it can reduce harsh \
            sibilance before it reaches your speakers or headphones.
            """)
            .fixedSize(horizontal: false, vertical: true)

            Label("Audio is processed live on this Mac.", systemImage: "lock.shield")
                .font(.callout)
            Label("Nothing is recorded, saved, or sent anywhere.", systemImage: "externaldrive.badge.xmark")
                .font(.callout)
            Label("Your microphone is never captured.", systemImage: "mic.slash")
                .font(.callout)

            if case .recoverableError(let error) = model.state, error.suggestsPrivacySettings {
                Divider()
                Text("Permission appears to be denied. Enable De-Esser under Privacy & Security ▸ System Audio Recording.")
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

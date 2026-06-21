import SwiftUI

/// The menu-bar popover (spec §12.1).
struct MenuBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusRow
            Divider()
            strengthSection
            gainReductionMeter
            Divider()
            bypassRow
            controlButtons
        }
        .padding(14)
        .frame(width: 300)
        .sheet(isPresented: $model.showPermissionExplainer) {
            PermissionExplainerView(model: model)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "waveform.badge.mic")
            Text("Teams De-Esser").font(.headline)
            Spacer()
            Toggle("", isOn: Binding(get: { model.enabled },
                                     set: { model.setEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Enable Teams audio processing")
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            Text(model.state.statusText(outputDeviceName: model.diagnostics.outputDeviceName))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var strengthSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Strength").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(strengthLabel).font(.caption).foregroundStyle(.secondary)
            }
            CommitSlider(value: Double(model.settings.strength), in: 0...1) {
                model.setStrength(Float($0))
            }
        }
    }

    private var strengthLabel: String {
        switch model.settings.strength {
        case ..<0.2: return "Gentle"
        case ..<0.45: return "Light"
        case ..<0.55: return "Default"
        case ..<0.8: return "Strong"
        default: return "Max"
        }
    }

    private var gainReductionMeter: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Gain reduction").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f dB", model.diagnostics.gainReductionDb))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GainReductionBar(valueDb: model.diagnostics.gainReductionDb, maxDb: 24)
        }
    }

    private var bypassRow: some View {
        Toggle(isOn: Binding(get: { model.bypass }, set: { model.setBypass($0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Bypass for comparison")
                Text("Keeps capture active; DSP crossfades to unity")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .disabled(!model.enabled)
    }

    private var controlButtons: some View {
        VStack(spacing: 6) {
            Button {
                model.requestManualRebuild()
            } label: {
                Label("Rebuild audio path", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.enabled)

            HStack {
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch model.state {
        case .running(let summary): return summary.bypassed ? .yellow : .green
        case .disabled: return .secondary
        case .waitingForTeams, .starting, .rebuilding, .requestingPermission: return .yellow
        case .recoverableError: return .red
        }
    }
}

/// A slider that holds its position in local `@State` so continuous dragging is
/// smooth and never mutates observable model state *during* a view update — the
/// committed value is reported from `.onChange`, which runs after the update,
/// avoiding the "Publishing changes from within view updates" warning.
///
/// It also re-syncs to `value` when the model changes externally (e.g. when a
/// preset is selected), suppressing the echo commit so that resync doesn't flip
/// the preset back to Custom.
struct CommitSlider: View {
    private let external: Double
    private let range: ClosedRange<Double>
    private let onCommit: (Double) -> Void

    @State private var value: Double
    @State private var suppressNextCommit = false

    init(value: Double, in range: ClosedRange<Double>, onCommit: @escaping (Double) -> Void) {
        self.external = value
        self.range = range
        self.onCommit = onCommit
        _value = State(initialValue: value)
    }

    private var epsilon: Double { (range.upperBound - range.lowerBound) * 1e-4 }

    var body: some View {
        Slider(value: $value, in: range)
            .onChange(of: value) { _, newValue in
                if suppressNextCommit {
                    suppressNextCommit = false
                    return
                }
                onCommit(newValue)
            }
            .onChange(of: external) { _, newExternal in
                // Model changed from elsewhere (e.g. preset picked): move the
                // thumb to match, without committing back.
                if abs(newExternal - value) > epsilon {
                    suppressNextCommit = true
                    value = newExternal
                }
            }
    }
}

/// Simple horizontal gain-reduction meter, 0…maxDb (spec §12.1).
struct GainReductionBar: View {
    let valueDb: Float
    let maxDb: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(Double(valueDb / maxDb), 0), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 8)
    }
}

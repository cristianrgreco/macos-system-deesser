import SwiftUI

/// Settings window (spec §12.2).
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            advancedTab
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 460, height: 460)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                        set: { model.setLaunchAtLogin($0) }))
                Toggle("Start enabled on launch", isOn: Binding(get: { model.startEnabledOnLaunch },
                                                                set: { model.setStartEnabledOnLaunch($0) }))
            }

            Section("De-essing") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Strength")
                        Spacer()
                        Text(String(format: "%.0f%%", model.settings.strength * 100))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    CommitSlider(value: Double(model.settings.strength), in: 0...1) {
                        model.setStrength(Float($0))
                    }
                    Text("Higher values tame more sibilance (sharp “s”/“sh” sounds). The midpoint is a balanced default; the top end is deliberately heavy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Diagnostics

    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                diagnosticGroup("Status") {
                    row("State", model.diagnostics.stateDescription)
                }

                diagnosticGroup("Detected Teams processes") {
                    if model.diagnostics.matchedProcesses.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.diagnostics.matchedProcesses) { p in
                            row("\(p.bundleID)", "pid \(p.pid)\(p.isRunningOutput ? " · output" : "")")
                        }
                    }
                }

                diagnosticGroup("Output device") {
                    row("Name", model.diagnostics.outputDeviceName)
                    row("UID", model.diagnostics.outputDeviceUID)
                    row("Sample rate", String(format: "%.0f Hz", model.diagnostics.sampleRate))
                    row("Channels", "\(model.diagnostics.outputChannelCount)")
                    row("Default fallback", model.diagnostics.usingDefaultFallback ? "Yes" : "No")
                }

                diagnosticGroup("Graph") {
                    row("Tap object ID", "\(model.diagnostics.tapObjectID)")
                    row("Aggregate object ID", "\(model.diagnostics.aggregateObjectID)")
                    row("Heartbeat", "\(model.diagnostics.heartbeat)")
                    row("Input peak", String(format: "%.3f", model.diagnostics.inputPeak))
                    row("Gain reduction", String(format: "%.2f dB", model.diagnostics.gainReductionDb))
                    row("Last Core Audio error", OSStatusFormatter.describe(model.diagnostics.lastCoreAudioError))
                }

                #if DEBUG
                diagnosticGroup("Debug target override") {
                    TextField("Bundle ID (blank = Microsoft Teams)", text: $model.debugTargetBundleID)
                        .textFieldStyle(.roundedBorder)
                    Text("DEBUG builds only. Lets you target a deterministic tone-producing app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif

                Button {
                    model.copyDiagnosticsReport()
                } label: {
                    Label("Copy diagnostic report", systemImage: "doc.on.clipboard")
                }
                Text("Reports contain metadata only — never audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func diagnosticGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

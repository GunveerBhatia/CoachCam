import SwiftUI

/// Settings sheet (the gear button). M11 adds more.
struct SettingsView: View {
    let camera: CameraService
    @ObservedObject var corrections: PersonTypeCorrections
    @ObservedObject var aiNames: AINameHistory
    @ObservedObject private var usage = APIUsage.shared
    @State private var memoryCounts = ObjectMemory.shared.counts()
    @State private var confirmResetMemory = false
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.showDebugOverlay) private var showDebugOverlay = false
    @AppStorage(SettingsKey.showGrid) private var showGrid = true
    @AppStorage(SettingsKey.showLevel) private var showLevel = true
    @AppStorage(SettingsKey.showPersonLabels) private var showPersonLabels = true

    @State private var apiKeyInput = ""
    @State private var maskedKey = KeychainStore.maskedKey
    @State private var confirmResetCorrections = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Guides") {
                    Toggle("Rule-of-thirds grid", isOn: $showGrid)
                    Toggle("Level line", isOn: $showLevel)
                }

                Section {
                    Toggle("Show person labels", isOn: $showPersonLabels)
                    LabeledContent("Your corrections", value: "\(corrections.entries.count)")
                    Button("Reset person-type corrections", role: .destructive) { confirmResetCorrections = true }
                        .disabled(corrections.entries.isEmpty)
                } header: {
                    Text("People")
                } footer: {
                    Text("Labels (kid, teen, man, woman, older man, older woman) are estimated on this phone and only used to pick poses and camera height. Tap a label to fix it. Corrections stay on this phone.")
                }

                Section {
                    if let masked = maskedKey {
                        LabeledContent("Saved key", value: masked)
                        Button("Remove key", role: .destructive) {
                            KeychainStore.deleteAPIKey()
                            maskedKey = nil
                            Log.info("Claude API key removed")
                        }
                    }
                    SecureField(maskedKey == nil ? "Paste your API key (sk-ant-…)" : "Replace key", text: $apiKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if KeychainStore.saveAPIKey(key) {
                            maskedKey = KeychainStore.maskedKey
                            apiKeyInput = ""
                            Log.info("Claude API key saved to Keychain")
                        }
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                    LabeledContent("API calls this week", value: "\(usage.thisWeek)")
                    LabeledContent("API calls total", value: "\(usage.total)")
                    LabeledContent("Answered from memory (free)", value: "\(usage.cacheHits)")
                } header: {
                    Text("Claude API (Identify with AI)")
                } footer: {
                    Text("Stored in the iPhone Keychain, never in the app's code. Claude is only contacted when you tap an AI button. Model: \(AppConfig.shared.ai.model).")
                }

                Section {
                    LabeledContent("Your corrections", value: "\(memoryCounts.yours)")
                    LabeledContent("Saved AI answers", value: "\(memoryCounts.ai)")
                    Button("Forget saved object names", role: .destructive) { confirmResetMemory = true }
                        .disabled(memoryCounts.yours + memoryCounts.ai == 0)
                } header: {
                    Text("Object names")
                } footer: {
                    Text("Objects are named on the phone first (detector → Apple classifier → your saved names → Apple Look Up). Claude is only asked when you tap Identify with AI, and every answer is saved so similar objects don't need another call.")
                }

                Section {
                    if aiNames.names.isEmpty {
                        Text("Nothing yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(aiNames.names.prefix(20), id: \.self) { Text($0) }
                        ShareLink("Share list (to add to vocabulary.json)", item: aiNames.names.joined(separator: "\n"))
                        Button("Clear list", role: .destructive) { aiNames.clear() }
                    }
                } header: {
                    Text("Objects identified by AI")
                } footer: {
                    Text("Send this list to Claude Code to add the useful names to the on-device detector's word list.")
                }

                Section("Debug") {
                    Toggle("Debug overlay", isOn: $showDebugOverlay)
                    NavigationLink("Debug log") { LogView() }
                    NavigationLink("Camera capabilities") { CapabilitiesView(camera: camera) }
                    LabeledContent("Photos access", value: PhotoLibrary.name(of: PhotoLibrary.addStatus))
                }

                Section {
                    LabeledContent("Coach Cam", value: AppVersion.full)
                    Text(ProvisioningInfo.summary)
                        .foregroundStyle(signatureColor)
                } header: {
                    Text("About")
                } footer: {
                    Text("Object detection: YOLOE by Ultralytics (AGPL-3.0). Person types: FairFace by Kärkkäinen & Joo (CC BY 4.0), race outputs removed.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete all your person-type corrections?", isPresented: $confirmResetCorrections,
                                titleVisibility: .visible) {
                Button("Reset corrections", role: .destructive) { corrections.reset() }
            }
            .confirmationDialog("Forget all saved object names (yours and AI answers)?", isPresented: $confirmResetMemory,
                                titleVisibility: .visible) {
                Button("Forget names", role: .destructive) {
                    ObjectMemory.shared.reset()
                    memoryCounts = ObjectMemory.shared.counts()
                }
            }
        }
    }

    /// Orange when fewer than 2 days are left, so you remember to refresh with iloader.
    private var signatureColor: Color {
        guard let date = ProvisioningInfo.expirationDate else { return .secondary }
        return date.timeIntervalSinceNow < 2 * 24 * 3600 ? .orange : .secondary
    }
}
/// Shows the log, newest at the bottom, with Share and Clear buttons.
struct LogView: View {
    @ObservedObject private var store = LogStore.shared

    var body: some View {
        ScrollViewReader { proxy in
            List(store.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date.formatted(date: .omitted, time: .standard) + " · " + entry.level.rawValue)
                        .font(.caption2)
                        .foregroundStyle(color(for: entry.level))
                    Text(entry.message)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            .listStyle(.plain)
            .onAppear {
                if let last = store.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .overlay {
            if store.entries.isEmpty {
                ContentUnavailableView("No log entries yet", systemImage: "doc.text")
            }
        }
        .navigationTitle("Debug log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: store.fileURL) { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { store.clear() } label: { Image(systemName: "trash") }
            }
        }
    }

    private func color(for level: LogStore.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }
}

/// What this iPhone's cameras allow apps to control. Share it with Claude after installing.
struct CapabilitiesView: View {
    let camera: CameraService
    @State private var report = "Checking the camera…"

    var body: some View {
        ScrollView {
            Text(report)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Camera capabilities")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: report) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear {
            camera.capabilityReport { text in
                report = text
                Log.info("Capability report generated")
            }
        }
    }
}

import SwiftUI

/// Settings sheet (the gear button). M11 adds more; for now: guides, debug tools, about.
struct SettingsView: View {
    let camera: CameraService
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.showDebugOverlay) private var showDebugOverlay = false
    @AppStorage(SettingsKey.showGrid) private var showGrid = true
    @AppStorage(SettingsKey.showLevel) private var showLevel = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Guides") {
                    Toggle("Rule-of-thirds grid", isOn: $showGrid)
                    Toggle("Level line", isOn: $showLevel)
                }

                Section("Debug") {
                    Toggle("Debug overlay", isOn: $showDebugOverlay)
                    NavigationLink("Debug log") { LogView() }
                    NavigationLink("Camera capabilities") { CapabilitiesView(camera: camera) }
                    LabeledContent("Photos access", value: PhotoLibrary.name(of: PhotoLibrary.addStatus))
                }

                Section("About") {
                    LabeledContent("Coach Cam", value: AppVersion.full)
                    Text(ProvisioningInfo.summary)
                        .foregroundStyle(signatureColor)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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

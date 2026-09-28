import Foundation

/// Keys for settings stored with `@AppStorage` (UserDefaults).
/// Views read and write them directly, e.g. `@AppStorage(SettingsKey.showGrid) var showGrid = true`.
enum SettingsKey {
    static let showDebugOverlay = "showDebugOverlay"
    static let showGrid = "showGrid"
    static let showLevel = "showLevel"
}

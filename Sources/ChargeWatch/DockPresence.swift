import AppKit

/// Whether Vedimac shows a Dock icon. Off by default: the app lives in the menu bar only.
enum DockPresence {
    private static let key = "showInDock"

    static var showInDock: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// Applies the saved choice. `.accessory` hides the Dock icon and keeps the menu-bar item.
    static func apply() {
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    static func save(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        apply()
    }
}

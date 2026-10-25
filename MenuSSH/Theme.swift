import AppKit

/// The user's appearance choice, applied app-wide so the popover, alerts and panels all match.
enum Theme: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return tr("跟隨系統", "Match System")
        case .light: return tr("淺色", "Light")
        case .dark: return tr("深色", "Dark")
        }
    }

    /// nil lets the app follow the system setting, including automatic day/night switching.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    private static let key = "menussh.theme"

    static var current: Theme {
        get { Theme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Popovers anchored to the menu bar take the menu bar's look unless told otherwise,
    /// so the popover gets the appearance set directly as well as the app.
    static func apply(to popover: NSPopover?) {
        NSApp.appearance = current.appearance
        popover?.appearance = current.appearance
    }
}

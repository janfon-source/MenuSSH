import Foundation

/// Where the app shows itself: an icon in the Dock, in the menu bar, or both. One of them is
/// always on, or there'd be no way back to the app.
enum Presence {
    private static let dockKey = "menussh.showInDock"
    private static let menuBarKey = "menussh.showInMenuBar"

    /// Posted after either changes, for the app to add or remove the icons.
    static let didChange = Notification.Name("menussh.presenceDidChange")

    static var showInDock: Bool {
        get { UserDefaults.standard.object(forKey: dockKey) as? Bool ?? false }
        set { set(dock: newValue, menuBar: showInMenuBar) }
    }

    static var showInMenuBar: Bool {
        get { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }
        set { set(dock: showInDock, menuBar: newValue) }
    }

    private static func set(dock: Bool, menuBar: Bool) {
        guard dock || menuBar else { return }
        UserDefaults.standard.set(dock, forKey: dockKey)
        UserDefaults.standard.set(menuBar, forKey: menuBarKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

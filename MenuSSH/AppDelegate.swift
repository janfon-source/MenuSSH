import AppKit
import ServiceManagement

/// Menu bar app: a status item that toggles a popover, and a Dock icon too if wanted (Presence).
/// Without the menu bar icon there's nothing to hang the popover from, so the window stays pinned.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // NSApplication holds its delegate weakly, so keep it alive here.
    private static var instance: AppDelegate?

    static func main() {
        // Run by ssh to ask for a password: hand the question to the app and print its answer.
        if Askpass.isHelper { Askpass.runHelper() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        instance = delegate
        app.delegate = delegate
        app.setActivationPolicy(Presence.showInDock ? .regular : .accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let main = MainViewController()
    /// Holds the content while it's pinned. Made the first time it's needed.
    private var panel: NSPanel?
    private static let panelFrameName = "MenuSSHPinnedWindow"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Every start is a fresh one: connections left from the last run are closed, and the
        // window opens on this Mac's terminal.
        DispatchQueue.global().async { SSHConnection.closeAllShared() }
        popover.contentViewController = main
        main.popover = popover
        main.applyPopoverBehavior()
        main.onPinChange = { [weak self] pinned in pinned ? self?.pin() : self?.unpin() }
        Theme.apply(to: popover)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = StatusIcon.image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // A transient popover should close at a click anywhere else, but after a menu has been
        // open in it AppKit can stop noticing clicks in other apps, so those close it here too.
        // While pinned, or while a panel or alert is up, the behavior isn't transient and it stays.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown, self.popover.behavior == .transient else { return }
            self.popover.performClose(nil)
        }

        applyPresence()
        NotificationCenter.default.addObserver(forName: Presence.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyPresence()
        }
        applyLanguage()
        NotificationCenter.default.addObserver(forName: Language.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyLanguage()
        }

        // Opened by hand: show the window so people see where it lives.
        // Started at login: stay quietly in the menu bar.
        if SMAppService.mainApp.status != .enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
    }

    private func applyLanguage() {
        NSApp.mainMenu = MainMenu.build(main: main)
        statusItem.button?.toolTip = tr("隨手SSH", "MenuSSH")
        statusItem.button?.setAccessibilityLabel(tr("隨手SSH", "MenuSSH"))
    }

    /// Adds or removes the Dock and menu bar icons to match the settings.
    private func applyPresence() {
        statusItem.isVisible = Presence.showInMenuBar
        main.canUnpin = Presence.showInMenuBar
        if !Presence.showInMenuBar, !main.pinned {
            main.pinned = true   // moves the content out of the popover, which needs the menu bar icon
        }
        let policy: NSApplication.ActivationPolicy = Presence.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            // Leaving the Dock deactivates the app; bring the window back where it was.
            if panel?.isVisible == true { DispatchQueue.main.async { self.showPanel() } }
        }
    }

    /// Clicking the Dock icon opens the window, as the menu bar icon does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else if main.pinned {
            panel?.isVisible == true ? panel?.orderOut(nil) : showPopover()
        } else {
            popover.isShown ? popover.performClose(nil) : showPopover()
        }
    }

    func showPopover() {
        if main.pinned { return showPanel() }
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        main.focus()
    }

    // MARK: Pinned window

    /// Moves the content out of the popover into a window of its own, at the same place and size,
    /// which can then be dragged anywhere and stays up when other apps are used.
    private func pin() {
        var rect: NSRect?
        if popover.isShown, let window = main.view.window {
            rect = window.convertToScreen(main.view.convert(main.view.bounds, to: nil))
            popover.animates = false
            popover.close()
            popover.animates = true
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Where the popover was, or else where the window was left. The view goes in as the content
        // view, not as a content view controller, whose preferred size the window would keep to
        // and so refuse to be resized.
        let frame = rect.map { panel.frameRect(forContentRect: $0) } ?? panel.frame
        popover.contentViewController = nil
        panel.contentView = main.view
        main.preferredContentSize = panel.contentRect(forFrameRect: frame).size
        holdPreferredSize(false)
        panel.setFrame(frame, display: false)
        main.pinnedWindow = panel
        if rect != nil { showPanel() }
    }

    /// Puts the content back in the popover under the menu bar icon, at the size it had before.
    private func unpin() {
        let wasShowing = panel?.isVisible ?? false
        panel?.orderOut(nil)
        panel?.contentView = NSView()
        holdPreferredSize(true)
        main.pinnedWindow = nil
        popover.contentViewController = main
        main.restorePopoverSize()
        if wasShowing { showPopover() }
    }

    private func showPanel() {
        if panel == nil || main.pinnedWindow == nil { pin() }
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        main.focus()
    }

    /// A window that looks much like the popover: no title bar to speak of, dragged by its top edge
    /// or any empty background, and floating above other apps' windows as the popover did.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: main.view.frame.size),
                            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: MainViewController.minSize)).size
        // Where it was left last time; the first time, just under the menu bar icon, if there is one.
        if !panel.setFrameUsingName(Self.panelFrameName) {
            if statusItem.isVisible, let button = statusItem.button?.window?.frame {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: button.midX - size.width / 2, y: button.minY - size.height - 6))
            } else {
                panel.center()
            }
        }
        panel.setFrameAutosaveName(Self.panelFrameName)
        return panel
    }

    /// The popover holds the view to the controller's preferred size with constraints just above
    /// the priority at which a window keeps its size, and a window held like that can't be resized
    /// by its edges. While pinned they're set just below it, so the window decides the size.
    private func holdPreferredSize(_ hold: Bool) {
        for constraint in main.view.constraints where constraint.identifier?.hasPrefix("NSViewController.preferredContentSize") == true {
            constraint.priority = hold ? .init(501) : .init(499)
        }
    }

    /// The popover left a constraint holding the view to the controller's preferred size, which
    /// would pull the window back; it follows the window's size instead while pinned.
    func windowDidResize(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel, main.pinnedWindow === panel else { return }
        main.preferredContentSize = panel.contentRect(forFrameRect: panel.frame).size
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("開啟隨手SSH", "Open MenuSSH"), action: #selector(openFromMenu), keyEquivalent: "").target = self
        // Every Host, straight into a Terminal window, without opening the popover first.
        let hosts = SSHConfig.hosts()
        if !hosts.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: tr("以\(TerminalApp.current.title)連線", "Connect in \(TerminalApp.current.title)"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for host in hosts {
                let item = menu.addItem(withTitle: host.alias, action: #selector(openTerminal(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = host.alias
                item.toolTip = host.summary
                item.indentationLevel = 1
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("結束隨手SSH", "Quit MenuSSH"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { showPopover() }

    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        main.openTerminal(SSHConnection(destination: alias), folder: nil)
    }
}

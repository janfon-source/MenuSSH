import AppKit

/// The main menu is never shown (accessory app), but its key equivalents still work while the
/// popover is key: ⌘T, ⌘U, ⌘D, ⌘↑ and the rest. Rebuilt when the language changes.
enum MainMenu {
    static func build(main controller: MainViewController) -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, tr("隨手SSH", "MenuSSH"))
        app.addItem(withTitle: tr("結束隨手SSH", "Quit MenuSSH"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, tr("檔案", "File"))
        add(file, tr("在外部終端機開啟 SSH 連線", "Open an SSH Session in the Terminal App"), #selector(MainViewController.openTerminalHere(_:)), "t", target: controller)
        add(file, tr("停止連線", "Stop the Connection"), #selector(MainViewController.stopConnection(_:)), "d", target: controller)
            .keyEquivalentModifierMask = [.command, .option]
        add(file, tr("新增連線設定…", "Add a Connection…"), #selector(MainViewController.addHost(_:)), "", target: controller)
        add(file, tr("管理連線設定…", "Connection Settings…"), #selector(MainViewController.manageConnections(_:)), "K", target: controller)
        add(file, tr("用文字編輯器開啟 ~/.ssh/config", "Open ~/.ssh/config in a Text Editor"), #selector(MainViewController.editConfig(_:)), "", target: controller)
        file.addItem(.separator())
        add(file, tr("開啟", "Open"), #selector(MainViewController.openSelected(_:)), "o", target: controller)
        add(file, tr("上傳…", "Upload…"), #selector(MainViewController.upload(_:)), "u", target: controller)
        add(file, tr("下載", "Download"), #selector(MainViewController.download(_:)), "d", target: controller)
        add(file, tr("下載到…", "Download To…"), #selector(MainViewController.downloadTo(_:)), "D", target: controller)
        add(file, tr("新增資料夾…", "New Folder…"), #selector(MainViewController.newFolder(_:)), "N", target: controller)
        add(file, tr("重新命名…", "Rename…"), #selector(MainViewController.renameFile(_:)), "", target: controller)
        add(file, tr("刪除…", "Delete…"), #selector(MainViewController.deleteFiles(_:)), "\u{8}", target: controller)
        add(file, tr("停止傳輸", "Stop Transfers"), #selector(MainViewController.stopTransfers(_:)), ".", target: controller)
        file.addItem(.separator())
        add(file, tr("關閉視窗", "Close Window"), #selector(MainViewController.closePopover(_:)), "w", target: controller)

        let edit = submenu(in: main, tr("編輯", "Edit"))
        add(edit, tr("還原", "Undo"), Selector(("undo:")), "z")
        add(edit, tr("重做", "Redo"), Selector(("redo:")), "Z")
        edit.addItem(.separator())
        add(edit, tr("剪下", "Cut"), #selector(NSText.cut(_:)), "x")
        add(edit, tr("拷貝", "Copy"), #selector(NSText.copy(_:)), "c")
        add(edit, tr("貼上", "Paste"), #selector(NSText.paste(_:)), "v")
        add(edit, tr("全選", "Select All"), #selector(NSText.selectAll(_:)), "a")
        add(edit, tr("拷貝路徑", "Copy Path"), #selector(MainViewController.copyPath(_:)), "C", target: controller)
            .keyEquivalentModifierMask = [.command, .option]

        let view = submenu(in: main, tr("顯示方式", "View"))
        add(view, "SSH", #selector(MainViewController.showSSH(_:)), "1", target: controller)
        add(view, "SFTP", #selector(MainViewController.showSFTP(_:)), "2", target: controller)
        view.addItem(.separator())
        add(view, tr("顯示或收起傳輸清單", "Show or Hide the Transfers"), #selector(MainViewController.toggleTransfers(_:)), "l", target: controller)
            .keyEquivalentModifierMask = [.command, .option]

        let terminal = submenu(in: main, tr("終端機", "Terminal"))
        add(terminal, tr("重新連線", "Reconnect"), #selector(MainViewController.reconnect(_:)), "R", target: controller)
        add(terminal, tr("清除回捲紀錄", "Clear Scrollback"), #selector(MainViewController.clearScrollback(_:)), "k", target: controller)
        terminal.addItem(.separator())
        add(terminal, tr("放大字體", "Bigger"), #selector(MainViewController.biggerText(_:)), "+", target: controller)
        add(terminal, tr("放大字體", "Bigger"), #selector(MainViewController.biggerText(_:)), "=", target: controller).isHidden = true
        add(terminal, tr("縮小字體", "Smaller"), #selector(MainViewController.smallerText(_:)), "-", target: controller)
        add(terminal, tr("實際大小", "Actual Size"), #selector(MainViewController.actualSizeText(_:)), "0", target: controller)
        terminal.addItem(.separator())
        add(terminal, tr("以 Option 鍵作為 Meta 鍵", "Use Option as Meta Key"), #selector(MainViewController.toggleOptionAsMeta(_:)), "", target: controller)

        let go = submenu(in: main, tr("前往", "Go"))
        add(go, tr("上一層資料夾", "Enclosing Folder"), #selector(MainViewController.goUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), target: controller)
        add(go, tr("家目錄", "Home Folder"), #selector(MainViewController.goHome(_:)), "H", target: controller)
        add(go, tr("前往資料夾…", "Go to Folder…"), #selector(MainViewController.goToFolder(_:)), "G", target: controller)
        add(go, tr("同步瀏覽本機與遠端", "Synchronized Browsing"), #selector(MainViewController.toggleSyncBrowsing(_:)), "y", target: controller)
            .keyEquivalentModifierMask = [.command, .option]
        add(go, tr("重新整理", "Refresh"), #selector(MainViewController.refresh(_:)), "r", target: controller)
        add(go, tr("顯示或隱藏隱藏檔", "Show or Hide Hidden Files"), #selector(MainViewController.toggleHidden(_:)), ".", target: controller)
            .keyEquivalentModifierMask = [.command, .shift]
        return main
    }

    private static func submenu(in main: NSMenu, _ title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                            target: AnyObject? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}

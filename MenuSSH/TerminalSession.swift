import AppKit

/// A terminal in the window: ssh running on a pseudo-terminal, riding the server's shared
/// connection; or, with no server, a shell on this Mac. Shown in a TerminalView, it keeps running
/// while other servers or the files are showing; when it ends, Return starts it again.
final class TerminalSession {
    /// Nil for this Mac's own shell.
    let connection: SSHConnection?
    let emulator: TerminalEmulator
    let view: TerminalView
    private var terminal: PseudoTerminal?
    private var lastBell = Date.distantPast

    /// The title the shell gives the window (OSC 0 or 2), usually user@host:folder.
    private(set) var title = ""
    /// The title, the size, or whether it's running changed.
    var onChange: (() -> Void)?
    /// Return pressed after the session ended: the window should connect again and call start().
    var onRestart: (() -> Void)?
    /// ssh has ended (signed out, or the connection dropped), with its exit code.
    var onEnded: ((Int32) -> Void)?

    var isRunning: Bool { terminal?.isRunning ?? false }
    /// Started once, at least: shows output (or an error) rather than nothing.
    private(set) var hasStarted = false

    init(connection: SSHConnection?) {
        self.connection = connection
        emulator = TerminalEmulator(cols: 80, rows: 24)
        view = TerminalView(emulator: emulator)
        emulator.onResponse = { [weak self] text in self?.terminal?.write(Array(text.utf8)) }
        emulator.onTitle = { [weak self] title in
            self?.title = title
            self?.onChange?()
        }
        emulator.onBell = { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastBell) > 0.5 else { return }
            self.lastBell = Date()
            NSSound.beep()
        }
        emulator.colorReport = { [weak view] background in view?.colorReport(background: background) ?? "rgb:0000/0000/0000" }
        view.onInput = { [weak self] bytes in
            guard let self else { return }
            if self.isRunning {
                self.terminal?.write(bytes)
            } else if bytes.contains(0x0D) {
                self.onRestart?()
            }
        }
        view.onResize = { [weak self] cols, rows in
            self?.terminal?.resize(cols: cols, rows: rows)
            self?.onChange?()
        }
    }

    /// Signs in on a new pseudo-terminal, in `folder` if given. The shared connection should be up
    /// first, so no password is asked; if it isn't, ssh asks in the terminal itself. With no
    /// server, starts the user's login shell in the home folder, as Terminal does.
    func start(folder: String?) {
        guard !isRunning else { return }
        hasStarted = true
        var name: String?, directory: String?
        let command: [String]
        if let connection {
            command = TerminalApp.command(for: connection, folder: folder)
        } else {
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
                ?? Self.loginShell ?? "/bin/zsh"
            command = [shell]
            name = "-" + (shell as NSString).lastPathComponent   // a login shell, which reads ~/.zprofile
            directory = folder.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "MenuSSH"
        // ssh passes LANG on (SendEnv), and the server's programs need a UTF-8 one for Chinese.
        if environment["LANG"]?.uppercased().contains("UTF-8") != true { environment["LANG"] = "en_US.UTF-8" }
        environment["LC_ALL"] = nil
        let terminal = PseudoTerminal()
        terminal.onOutput = { [weak self] bytes in
            self?.emulator.feed(bytes)
            self?.view.outputArrived()
        }
        terminal.onExit = { [weak self] code in
            guard let self else { return }
            let ended = self.connection == nil
                ? tr("〔本機終端機已結束。按 Return 重新開啟。〕", "[The shell has ended. Press Return to start another.]")
                : tr("〔連線已結束\(code == 0 ? "" : "（代碼 \(code)）")。從連線選單再選一次可重新連線。〕",
                     "[Session ended\(code == 0 ? "" : " (code \(code))"). Choose it from the connection menu to connect again.]")
            self.emulator.feed("\r\n\u{1B}[0m\u{1B}[2m" + ended + "\u{1B}[0m\r\n")
            self.view.outputArrived()
            self.title = ""
            self.onChange?()
            self.onEnded?(code)
        }
        do {
            try terminal.start(command[0], Array(command.dropFirst()), name: name, directory: directory, environment: environment,
                               cols: emulator.cols, rows: emulator.rows)
            self.terminal = terminal
            onChange?()
        } catch {
            show(error: error.localizedDescription)
        }
    }

    /// A message in the terminal, in red, for a connection that couldn't be made.
    func show(error message: String) {
        hasStarted = true
        emulator.feed("\r\n\u{1B}[31m" + message.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1B}[0m\r\n\u{1B}[2m"
                      + tr("按 Return 再試一次。", "Press Return to try again.") + "\u{1B}[0m\r\n")
        view.outputArrived()
    }

    /// The shell set for this account (System Settings → Users & Groups), as Terminal uses.
    private static var loginShell: String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Ends the session, as closing a Terminal window does.
    func close() {
        terminal?.terminate()
    }
}

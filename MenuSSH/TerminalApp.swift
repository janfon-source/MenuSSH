import AppKit

/// The terminal app SSH sessions open in: Terminal, or iTerm2 when it's installed and chosen.
enum TerminalApp: String, CaseIterable {
    case terminal = "com.apple.Terminal"
    case iTerm = "com.googlecode.iterm2"

    var title: String {
        switch self {
        case .terminal: return tr("終端機", "Terminal")
        case .iTerm: return "iTerm2"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }

    static var installed: [TerminalApp] { allCases.filter { $0.appURL != nil } }

    private static let key = "menussh.terminal"

    static var current: TerminalApp {
        get {
            let chosen = TerminalApp(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .terminal
            return chosen.appURL != nil ? chosen : .terminal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// The ssh command that signs in to the server, in the given folder if any. It goes through the
    /// app's shared connection when that's up (so no password again) and connects on its own otherwise.
    static func command(for connection: SSHConnection, folder: String?) -> [String] {
        var arguments = ["/usr/bin/ssh", "-o", "ControlPath=\(SSHConnection.controlPath)", "-o", "ControlMaster=no"]
        if let port = connection.port { arguments += ["-o", "Port=\(port)"] }
        if let folder {
            arguments += ["-t", connection.destination, "cd \(SSHConnection.shellPath(folder)) 2>/dev/null; exec \"$SHELL\" -l"]
        } else {
            arguments.append(connection.destination)
        }
        return arguments
    }

    /// The command as it would be typed in a shell.
    static func commandLine(for connection: SSHConnection, folder: String?) -> String {
        command(for: connection, folder: folder).map { arg in
            arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./=@:%".contains($0) } ? arg : SSHConnection.shellQuote(arg)
        }.joined(separator: " ")
    }

    /// Opens a new window in the terminal app signed in to the server. It's done with a .command
    /// file, which both apps run in a new window and which needs no permission to control them;
    /// the file deletes itself as it starts.
    func open(_ connection: SSHConnection, folder: String?) throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuSSH-\(UUID().uuidString.prefix(8)).command")
        let text = """
            #!/bin/zsh
            rm -f -- "$0"
            clear
            exec \(Self.commandLine(for: connection, folder: folder))

            """
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard let appURL else { throw SSHError(message: tr("找不到\(title)。", "\(title) isn’t installed.")) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: configuration)
    }
}

import Foundation

/// The ssh command a terminal tab runs to sign in to a server.
enum SSHCommand {
    /// Signs in to the server, in the given folder if any. It goes through the app's shared
    /// connection when that's up (so no password again) and connects on its own otherwise.
    static func arguments(for connection: SSHConnection, folder: String?) -> [String] {
        var arguments = ["/usr/bin/ssh", "-o", "ControlPath=\(SSHConnection.controlPath)", "-o", "ControlMaster=no"]
        if let port = connection.port { arguments += ["-o", "Port=\(port)"] }
        if let folder {
            arguments += ["-t", connection.destination, "cd \(SSHConnection.shellPath(folder)) 2>/dev/null; exec \"$SHELL\" -l"]
        } else {
            arguments.append(connection.destination)
        }
        return arguments
    }
}

import Foundation

/// A question ssh asks while connecting: a password, a key's passphrase, or whether to trust a
/// server it hasn't seen before.
struct AskpassPrompt: Codable {
    var text: String
    /// SSH_ASKPASS_PROMPT: "confirm" for a yes-or-no question, "none" for a notice; nil for an answer to type.
    var style: String?

    /// ssh's "Are you sure you want to continue connecting (yes/no/[fingerprint])?".
    var isHostKey: Bool { text.contains("(yes/no") }
    var isPassword: Bool { text.lowercased().hasSuffix("password:") || text.lowercased().hasSuffix("password: ") }
}

/// ssh asks for passwords by running the program in SSH_ASKPASS, which this app points at its own
/// executable. Started that way (with MENUSSH_ASKPASS_DIR set), the program doesn't open a window:
/// it leaves the question in that folder as `<id>.prompt`, waits for the running app to answer
/// with `<id>.answer` or `<id>.cancel`, and prints the answer for ssh. The folder is made for
/// each connection and only this user can open it.
enum Askpass {
    static let folderVariable = "MENUSSH_ASKPASS_DIR"

    static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("menussh-askpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    // MARK: In the app

    /// Answers the questions waiting in `folder`, if any; `ask` returns nil to refuse.
    static func answerPending(in folder: URL, ask: (AskpassPrompt) -> String?) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".prompt") {
            let url = folder.appendingPathComponent(name)
            let id = String(name.dropLast(".prompt".count))
            guard let data = try? Data(contentsOf: url),
                  let prompt = try? JSONDecoder().decode(AskpassPrompt.self, from: data) else { continue }
            try? FileManager.default.removeItem(at: url)
            if let answer = ask(prompt) {
                try? Data(answer.utf8).write(to: folder.appendingPathComponent(id + ".answer"), options: .atomic)
            } else {
                FileManager.default.createFile(atPath: folder.appendingPathComponent(id + ".cancel").path, contents: nil)
            }
        }
    }

    // MARK: Run by ssh

    /// Whether this process was started by ssh to ask something, rather than as the app.
    static var isHelper: Bool { ProcessInfo.processInfo.environment[folderVariable] != nil }

    static func runHelper() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[folderVariable] else { exit(1) }
        let folder = URL(fileURLWithPath: path)
        let prompt = AskpassPrompt(text: CommandLine.arguments.dropFirst().joined(separator: " "),
                                   style: environment["SSH_ASKPASS_PROMPT"])
        // A notice (a security key waiting for a touch, say) needs no answer, and ssh doesn't wait for one.
        if prompt.style == "none" { exit(0) }
        let id = UUID().uuidString
        guard let data = try? JSONEncoder().encode(prompt),
              (try? data.write(to: folder.appendingPathComponent(id + ".prompt"), options: .atomic)) != nil else { exit(1) }
        let answer = folder.appendingPathComponent(id + ".answer"), cancel = folder.appendingPathComponent(id + ".cancel")
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if let data = try? Data(contentsOf: answer) {
                try? FileManager.default.removeItem(at: answer)
                FileHandle.standardOutput.write(data + Data("\n".utf8))
                exit(0)
            }
            // Refused, or the app gave up on the connection and took the folder away.
            if FileManager.default.fileExists(atPath: cancel.path) || !FileManager.default.fileExists(atPath: folder.path) { exit(1) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        exit(1)
    }
}

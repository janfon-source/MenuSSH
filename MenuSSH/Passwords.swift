import CryptoKit
import Foundation

/// Server passwords and key passphrases the user chose to remember, by server and question,
/// kept by the app itself: encrypted with AES-GCM in ~/Library/Application Support/MenuSSH,
/// under a random key beside them, both readable only by this user. Unlike the keychain, it
/// doesn't ask again after each new build (an app without an Apple team ID is a new app to the
/// keychain every time it's built). As in 隨手MySQL.
enum Passwords {
    private struct Store: Codable {
        var passwords: [String: String] = [:]
    }

    static var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MenuSSH", isDirectory: true)
    private static var keyURL: URL { folder.appendingPathComponent("key") }
    private static var storeURL: URL { folder.appendingPathComponent("passwords") }

    /// What a saved answer is filed under: the server, and for anything but its password (a key's
    /// passphrase, say) the question itself.
    static func account(_ server: String, _ prompt: AskpassPrompt) -> String {
        prompt.isPassword ? server : server + "|" + prompt.text.trimmingCharacters(in: .whitespaces)
    }

    static func password(for account: String) -> String? {
        load().passwords[account]
    }

    static func save(_ password: String, for account: String) {
        var store = load()
        store.passwords[account] = password
        save(store)
    }

    /// Forgets everything saved for a server.
    static func deleteAll(for server: String) {
        var store = load()
        store.passwords = store.passwords.filter { $0.key != server && !$0.key.hasPrefix(server + "|") }
        save(store)
    }

    static func hasAny(for server: String) -> Bool {
        load().passwords.keys.contains { $0 == server || $0.hasPrefix(server + "|") }
    }

    // MARK: Files

    private static func load() -> Store {
        guard let sealed = try? Data(contentsOf: storeURL), let key = key(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
        return store
    }

    private static func save(_ store: Store) {
        guard let key = key(), let data = try? JSONEncoder().encode(store),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        write(sealed, to: storeURL)
    }

    /// The key, made the first time.
    private static func key() -> SymmetricKey? {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        guard write(key.withUnsafeBytes { Data($0) }, to: keyURL) else { return nil }
        return key
    }

    /// Writes a file only this user can read, in a folder only this user can open.
    @discardableResult
    private static func write(_ data: Data, to url: URL) -> Bool {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try data.write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

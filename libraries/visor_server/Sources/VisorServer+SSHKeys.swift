// A device's SSH key, authorized here by the device itself: a client
// that is in already (by the password, or a path that asks nothing)
// hands its public key over, and it goes into this user's
// `authorized_keys`, so the device's next connection can come through
// the computer's own SSH, with no password asked. The password already
// lets a client run the agents as this user; a key for SSH is no more.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Where the keys go: this user's, or where a test puts them.
    public static var authorizedKeysPathOverride: String?
    static var authorizedKeysPath: String {
        authorizedKeysPathOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/authorized_keys", isDirectory: false).path
    }

    /// The comment a line Visor adds ends in: `visor:<device>`, so
    /// "Forget this device" and Uninstall… take out Visor's lines alone,
    /// never one put there by hand. (0.64's lines say just `visor`.)
    public static let keyTag = "visor:"

    /// The key types a line may be of.
    static let keyTypes: Set<String> = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                                        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"]

    /// A public key line's type and key; nil for anything else.
    static func parsedKey(_ line: String) -> (type: String, blob: String, comment: String)? {
        let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = key.split(separator: " ")
        guard parts.count >= 2, key.count < 4096, !key.contains("\n"), keyTypes.contains(String(parts[0])),
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }) else { return nil }
        return (String(parts[0]), String(parts[1]), parts.dropFirst(2).joined(separator: " "))
    }

    /// `visor:<device>`: the device's name in letters, digits, `-`, `_`
    /// and `.` alone (anything else a `-`), "device" when it has none.
    public static func tag(device: String) -> String {
        let name = String(device.trimmingCharacters(in: .whitespaces).prefix(64).map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character)) ? character : "-"
        })
        return keyTag + (name.isEmpty ? "device" : name)
    }

    /// Whether an authorized_keys line is one Visor added: its comment
    /// `visor:<device>`, or 0.64's `visor`.
    public static func isVisorsKeyLine(_ line: Substring) -> Bool {
        let words = line.split(separator: " ")
        guard words.count >= 3, let last = words.last else { return false }
        return last.hasPrefix(keyTag) || (words.count == 3 && last == "visor")
    }

    /// Takes a public key line (`ssh-ed25519 AAAA… comment`) into the
    /// authorized keys, once, tagged with the device it's for
    /// (`visor:<device>`: the device's name, else the line's comment); the
    /// folder and the file made as sshd wants them (0700, 0600). A key
    /// there already as 0.64 added it (comment `visor`) is tagged now. Nil
    /// when done; otherwise what is wrong.
    func authorizeSSHKey(_ line: String, device: String? = nil) -> String? {
        guard let key = Self.parsedKey(line) else { return "That is not a public key line." }
        let named = (device ?? "").isEmpty ? key.comment : device ?? ""
        let tagged = "\(key.type) \(key.blob) \(Self.tag(device: named))"
        let path = Self.authorizedKeysPath
        let folder = (path as NSString).deletingLastPathComponent
        let files = FileManager.default
        do {
            try files.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let kept = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            var lines = kept.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            if let index = lines.firstIndex(where: { $0.split(separator: " ").dropFirst().first.map(String.init) == key.blob }) {
                // There already: as it is, unless it's 0.64's untagged line.
                guard lines[index].split(separator: " ").count == 3, lines[index].hasSuffix(" visor") else { return nil }
                lines[index] = tagged
            } else {
                lines.append(tagged)
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            Self.log("an SSH key was authorized for \(named.isEmpty ? "a device" : named)")
            return nil
        } catch {
            return "The key could not be kept: \(error.localizedDescription)"
        }
    }

    /// "Forget this device": the device's key (a public key line) taken
    /// out of the authorized keys, where Visor added it (its line tagged
    /// `visor:…`, or 0.64's `visor`); a line put there by hand stays. Nil
    /// when done (or there was none); otherwise what is wrong.
    func forgetSSHKey(_ line: String) -> String? {
        guard let key = Self.parsedKey(line) else { return "That is not a public key line." }
        let path = Self.authorizedKeysPath
        guard let kept = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var lines = kept.split(separator: "\n", omittingEmptySubsequences: false)
        let before = lines.count
        lines.removeAll { $0.split(separator: " ").dropFirst().first.map(String.init) == key.blob && Self.isVisorsKeyLine($0) }
        guard lines.count != before else { return nil }
        do {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            Self.log("an SSH key Visor had authorized was forgotten")
            return nil
        } catch {
            return "The key could not be forgotten: \(error.localizedDescription)"
        }
    }
}

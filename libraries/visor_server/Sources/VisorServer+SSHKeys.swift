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
        authorizedKeysPathOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/authorized_keys").path
    }

    /// Takes a public key line (`ssh-ed25519 AAAA… comment`) into the
    /// authorized keys, once; the folder and the file made as sshd
    /// wants them (0700, 0600). Nil when done; otherwise what is wrong.
    func authorizeSSHKey(_ line: String) -> String? {
        let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Type, the key itself, and a comment of any words.
        let parts = key.split(separator: " ")
        guard parts.count >= 2, key.count < 4096, !key.contains("\n"),
              ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"].contains(String(parts[0])),
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }) else {
            return "That is not a public key line."
        }
        let path = Self.authorizedKeysPath
        let folder = (path as NSString).deletingLastPathComponent
        let files = FileManager.default
        do {
            try files.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var kept = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let blob = parts[1]
            if kept.split(separator: "\n").contains(where: { $0.split(separator: " ").dropFirst().first == blob }) { return nil }
            if !kept.isEmpty, !kept.hasSuffix("\n") { kept += "\n" }
            kept += key + "\n"
            try kept.write(toFile: path, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            Self.log("an SSH key was authorized for \(parts.count > 2 ? parts[2...].joined(separator: " ") : "a device")")
            return nil
        } catch {
            return "The key could not be kept: \(error.localizedDescription)"
        }
    }
}

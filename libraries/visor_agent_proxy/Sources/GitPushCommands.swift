import Foundation

/// A git push's command list, as `git-receive-pack`'s request starts with it
/// (docs/github-gate-rules.md, [G3]): pkt-lines up to the first flush,
/// `shallow` lines first, then `<old> <new> <ref>` per ref, the first with
/// its capabilities after a NUL. The pack that follows is never read.
struct GitPushCommands: Equatable, Sendable {
    struct Command: Equatable, Sendable {
        var old: String
        var new: String
        var ref: String
    }

    var commands: [Command]
    var capabilities: [String]

    /// What `bytes` begin with, and how many bytes the list took (its flush
    /// included): `incomplete` while more may come, `invalid` for what isn't
    /// a command list.
    enum Reading: Equatable, Sendable {
        case list(GitPushCommands, length: Int)
        case incomplete
        case invalid
    }

    static func read(_ bytes: [UInt8]) -> Reading {
        var at = 0
        var commands: [Command] = []
        var capabilities: [String] = []
        while true {
            guard at + 4 <= bytes.count else { return .incomplete }
            guard let text = String(bytes: bytes[at..<at + 4], encoding: .ascii), let length = Int(text, radix: 16) else { return .invalid }
            if length == 0 {
                return .list(GitPushCommands(commands: commands, capabilities: capabilities), length: at + 4)
            }
            guard length > 4, length <= 65520 else { return .invalid }
            guard at + length <= bytes.count else { return .incomplete }
            var line = Array(bytes[at + 4..<at + length])
            at += length
            if line.last == 0x0A { line.removeLast() }
            var head = line
            if let nul = line.firstIndex(of: 0) {
                head = Array(line[..<nul])
                guard commands.isEmpty, capabilities.isEmpty,
                      let given = String(bytes: line[(nul + 1)...], encoding: .utf8) else { return .invalid }
                capabilities = given.split(separator: " ").map(String.init)
            }
            guard let command = String(bytes: head, encoding: .utf8) else { return .invalid }
            if command.hasPrefix("shallow ") {
                guard commands.isEmpty, GitRefName.isSHA(String(command.dropFirst(8))) else { return .invalid }
                continue
            }
            if command.hasPrefix("push-cert") {
                // A signed push: its certificate in place of the commands.
                return .list(GitPushCommands(commands: [], capabilities: ["push-cert"]), length: at)
            }
            let parts = command.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, GitRefName.isSHA(parts[0]), GitRefName.isSHA(parts[1]), !parts[2].isEmpty else { return .invalid }
            commands.append(Command(old: parts[0], new: parts[1], ref: parts[2]))
        }
    }
}

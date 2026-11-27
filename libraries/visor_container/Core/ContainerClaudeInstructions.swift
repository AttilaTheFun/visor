// The Sessions container's Claude's own instructions (docs/containers.md,
// "Its Claude's instructions"; Logan, 26 Nov 2026): CLAUDE.md in its
// Claude folder (`<Sessions>/.claude/CLAUDE.md`, CLAUDE_CONFIG_DIR's, which
// every Claude in the container reads as a user's ~/.claude/CLAUDE.md),
// made at a boot when there's none: it imports the checkouts' AGENTS.md
// (`@/Volumes/Sources/AGENTS.md`), the rules the agents working there keep,
// and says where the agent is and that nothing is cloned for it. One there
// already (Manager wrote one) is never written over, nor a link by that
// name, even one that leads nowhere; and none is made while the container
// shares no checkouts' folder, which its import needs.

import Foundation

public struct ContainerClaudeInstructions: Equatable, Sendable {
    /// The container's Claude folder (CLAUDE_CONFIG_DIR), at the same path
    /// on the Mac as in the guest.
    public var folder: String
    /// The checkouts' folder it shares (the Sources volume, else Settings'
    /// `container.checkouts`); nil: none.
    public var checkouts: String?

    public init(folder: String, checkouts: String?) {
        self.folder = folder
        self.checkouts = checkouts
    }

    /// The file: Claude's own, in its folder.
    public var file: URL { URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("CLAUDE.md") }

    /// What a new one says, for the checkouts' folder `checkouts` and the
    /// Sessions volume `sessions`.
    public static func text(checkouts: String, sessions: String) -> String {
        """
        @\(checkouts)/AGENTS.md

        # In the Sessions container

        You run in Visor's Sessions container, a Linux VM on this Mac. Your \
        session's folder is on the Sessions volume (\(sessions)), at the same \
        path as on the Mac. Nothing is cloned for you: clone the repositories \
        you need into \(checkouts), and push what you do there.

        Visor made this file because there was none, and never writes over it: \
        it's yours to change.

        """
    }

    /// The file made, when there's none and the container shares a
    /// checkouts' folder; said in the log. One there is left as it is.
    public func write(log: (String) -> Void) {
        guard let checkouts else { return }
        let files = FileManager.default
        // A link by that name, even one leading nowhere, is there.
        if files.fileExists(atPath: file.path) || (try? files.destinationOfSymbolicLink(atPath: file.path)) != nil { return }
        let sessions = (folder as NSString).deletingLastPathComponent
        let staged = file.deletingLastPathComponent().appendingPathComponent(".CLAUDE.md.visor-\(UUID().uuidString.prefix(8))")
        defer { try? files.removeItem(at: staged) }
        // Made beside it, then linked in by its name, which fails where one
        // was made meanwhile: never over it.
        guard (try? files.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil,
              files.createFile(atPath: staged.path, contents: Data(Self.text(checkouts: checkouts, sessions: sessions).utf8),
                               attributes: [.posixPermissions: 0o644]),
              link(staged.path, file.path) == 0 else {
            log("container: \(file.path) couldn't be made")
            return
        }
        log("container: \(file.path) made, importing \(checkouts)/AGENTS.md")
    }
}

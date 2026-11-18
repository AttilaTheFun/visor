// Where a handed-back session's conversation goes here, as the server sees
// it when its wrapper's ReturnConversation begins (VisorServer.handBackArriving):
// the session, the agent that returns it, the folder the session moves back
// to and so Claude's key for it, and how much may come.

import Foundation

package struct HandBackTarget: Sendable {
    /// The session moving back.
    package let session: String
    /// The runner's agent whose conversation it is (its move's).
    package let agent: String
    /// The folder the session works in here once back: what its
    /// conversation is keyed for.
    package let cwd: String
    /// Claude's own folder here (~/.claude, or $CLAUDE_CONFIG_DIR).
    package let claudeFolder: URL
    /// The folder Claude keeps `cwd`'s conversations in under `projects/`
    /// (ClaudeSessionFiles.projectDirectoryName), the one place written.
    package let key: String
    package let limits: HandBackLimits
    /// The bytes free on the disk Claude's folder is on; nil when the
    /// system doesn't say.
    package let free: Int?

    package init(session: String, agent: String, cwd: String, claudeFolder: URL, key: String, limits: HandBackLimits, free: Int?) {
        self.session = session
        self.agent = agent
        self.cwd = cwd
        self.claudeFolder = claudeFolder
        self.key = key
        self.limits = limits
        self.free = free
    }

    /// The session's project folder here: `<Claude's folder>/projects/<key>`.
    package var project: URL {
        claudeFolder.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }
}

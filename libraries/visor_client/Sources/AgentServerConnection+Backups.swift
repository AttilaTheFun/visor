// A server's sessions backed up to a folder on its computer and restored
// from one (`/api/backups`): what a computer's settings offer before an
// update that might lose sessions.

import VisorProtocol

extension AgentServerConnection {
    /// Whether this computer's server backs its sessions up.
    public var backsUp: Bool { server.backsUp }

    /// Backs up every session not archived (their conversations; the
    /// projects stay where they are): the backup.
    public func backUpSessions() async throws -> SessionBackup {
        try await server.backUp(sessions: nil, projects: false)
    }

    /// The backups kept on the computer, newest first.
    public func sessionBackups() async throws -> [SessionBackup] {
        try await server.backups()
    }

    /// Puts back what the backup at `path` holds and this computer no
    /// longer has: what became of each session. The sessions it started
    /// again are listed at once.
    public func restoreSessions(from path: String) async throws -> SessionBackup {
        let (backup, list) = try await server.restore(path, sessions: nil)
        take(list, replacing: false)
        return backup
    }
}

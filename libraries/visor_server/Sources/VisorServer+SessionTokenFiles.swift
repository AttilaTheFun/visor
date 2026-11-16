// A native session's token, written to a file its agent is told of
// (VISOR_TOKEN_FILE): `<Visor's data>/hosts/<session>/token`, the folder
// this user's alone (700) and the file too (600). Re-minted every hour,
// and at once when the signing keys rotate, so the token in it is never
// near its day's end; visor-agent-host's MCP bridge reads it on each call
// (VISOR_TOKEN, the one minted when the agent started, only where an older
// host doesn't read the file). Gone with the session, or its archiving.

import Foundation
import VisorSystem

extension VisorServer {
    /// How often the token files are re-minted.
    static let sessionTokenRefreshInterval: Duration = .seconds(3600)

    /// The session's token file.
    static func sessionTokenFile(of session: String) -> URL {
        let folder = session.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return HostFolders.dataFolder.appendingPathComponent("hosts", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true).appendingPathComponent("token", isDirectory: false)
    }

    /// A fresh token for the session's native agent, written to its file
    /// (600, replacing the one before at once): the token.
    @discardableResult
    func writeSessionToken(of session: String) -> String {
        let token = agentToken(for: session)
        let file = Self.sessionTokenFile(of: session)
        let folder = file.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            // Made 600 before the token is in it, then moved over the one
            // before: a reader sees the old file or the new, never half.
            let staged = folder.appendingPathComponent("token.\(UUID().uuidString.prefix(8)).new", isDirectory: false)
            guard manager.createFile(atPath: staged.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            if manager.fileExists(atPath: file.path) {
                _ = try manager.replaceItemAt(file, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: file)
            }
        } catch {
            Self.log("could not write \(session)'s token file at \(file.path): \(error)")
        }
        return token
    }

    /// The session's token file gone.
    func removeSessionTokenFile(of session: String) {
        let file = Self.sessionTokenFile(of: session)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Every live native session's token file re-minted: those not
    /// archived, not run on a runner (whose agents' tokens come over their
    /// driver stream).
    func refreshSessionTokenFiles() {
        for record in sessions where !record.info.archived && !record.driven {
            writeSessionToken(of: record.info.id)
        }
    }

    /// Re-mints the token files every `sessionTokenRefreshInterval` while
    /// the server runs.
    func keepSessionTokensFresh() {
        sessionTokenRefresh?.cancel()
        sessionTokenRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sessionTokenRefreshInterval)
                guard !Task.isCancelled, let self else { return }
                self.refreshSessionTokenFiles()
            }
        }
    }
}

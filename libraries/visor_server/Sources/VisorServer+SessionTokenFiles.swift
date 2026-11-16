// A native session's token, written to a file its agent is told of
// (VISOR_TOKEN_FILE): `<Visor's data>/hosts/<session's name>/token`, the
// folder this user's alone (700) and the file too (600). Its folder's name
// is SessionPathName's: the id itself where it is plain (a UUID), else a
// hash of it, so a client's id of `.`, `..`, `` or `a/b` never names
// `hosts/` itself, anything outside it, or another session's folder.
// Re-minted every hour, and at once when the signing keys rotate, so the
// token in it is never near its day's end; visor-agent-host's MCP bridge
// reads it on each call (VISOR_TOKEN, the one minted when the agent
// started, only where an older host doesn't read the file). Gone with the
// session, or its archiving: the `token` file alone, then its folder only
// if nothing else is in it. Nothing is written or removed unless its path
// is strictly inside `hosts/`, whose other files (hosts.log, the hosts'
// sockets) are never touched.

import Foundation
import VisorSystem

extension VisorServer {
    /// How often the token files are re-minted.
    static let sessionTokenRefreshInterval: Duration = .seconds(3600)

    /// The folder the token files' folders are in.
    static var sessionTokenFolders: URL {
        HostFolders.dataFolder.appendingPathComponent("hosts", isDirectory: true)
    }

    /// The session's token file.
    static func sessionTokenFile(of session: String) -> URL {
        sessionTokenFolders.appendingPathComponent(SessionPathName.of(session), isDirectory: true)
            .appendingPathComponent("token", isDirectory: false)
    }

    /// Whether `file` is a token file's place: `token`, in a folder of its
    /// own strictly inside `hosts/`.
    static func isSessionTokenFile(_ file: URL) -> Bool {
        let folder = file.deletingLastPathComponent()
        return file.lastPathComponent == "token" && SessionPathName.isInside(folder, sessionTokenFolders)
            && folder.deletingLastPathComponent().standardizedFileURL.path == sessionTokenFolders.standardizedFileURL.path
    }

    /// A fresh token for the session's native agent, written to its file
    /// (600, replacing the one before at once): the token.
    @discardableResult
    func writeSessionToken(of session: String) -> String {
        let token = agentToken(for: session)
        let file = Self.sessionTokenFile(of: session)
        guard Self.isSessionTokenFile(file) else {
            Self.log("not writing \(session)'s token file: \(file.path) isn't a token file's place in \(Self.sessionTokenFolders.path)")
            return token
        }
        // No signing key to mint with (SigningKeys couldn't read its keys):
        // the file before is left as it is.
        guard !token.isEmpty else { return token }
        let folder = file.deletingLastPathComponent()
        let manager = FileManager.default
        // Made 600 before the token is in it, then moved over the one
        // before: a reader sees the old file or the new, never half.
        let staged = folder.appendingPathComponent("token.\(UUID().uuidString.prefix(8)).new", isDirectory: false)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
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
            // The staged copy isn't left behind.
            try? manager.removeItem(at: staged)
            Self.log("could not write \(session)'s token file at \(file.path): \(error)")
        }
        return token
    }

    /// The session's token file gone: the `token` file alone (never a
    /// folder of that name), then its folder, only if nothing else is in
    /// it. Nothing outside `hosts/<its folder>/`.
    func removeSessionTokenFile(of session: String) {
        let file = Self.sessionTokenFile(of: session)
        guard Self.isSessionTokenFile(file) else {
            Self.log("not removing \(session)'s token file: \(file.path) isn't a token file's place in \(Self.sessionTokenFolders.path)")
            return
        }
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        if manager.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue {
            try? manager.removeItem(at: file)
        }
        let folder = file.deletingLastPathComponent()
        // Not recursive: an emptied folder goes, one with anything in it
        // stays.
        if let left = try? manager.contentsOfDirectory(atPath: folder.path), left.isEmpty {
            try? manager.removeItem(at: folder)
        }
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

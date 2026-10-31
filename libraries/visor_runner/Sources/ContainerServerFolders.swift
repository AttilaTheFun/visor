import Foundation

/// The Runner's container servers as their folders say (docs/co-tenancy.md):
/// each a folder of `folders` holding its `server.json` (what it should be),
/// its `state.json` (what the Runner's agent last found), and marks for an
/// upgrade or a removal. The menu bar app writes what should be here; the
/// agent (ContainerServers) makes it so. Quick: files alone.
public struct ContainerServerFolders: Sendable {
    public let folders: URL

    public init(folders: URL) {
        self.folders = folders
    }

    public func folder(_ id: String) -> URL { folders.appendingPathComponent(id, isDirectory: true) }

    /// The container servers there are: the folders with a `server.json`.
    public func servers() -> [ContainerServerSpec] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folders, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { try? ContainerServerSpec.read($0) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// What the Runner's agent last found of a server.
    public func state(_ id: String) -> ContainerServerState? { ContainerServerState.read(folder(id)) }

    /// A container server as it should be: its folder (this user's alone)
    /// and `server.json` written, stopped or not. Nil, or what went wrong.
    public func want(_ spec: ContainerServerSpec) -> String? {
        do {
            try FileManager.default.createDirectory(at: folder(spec.id), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try spec.write(folder(spec.id))
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// The server to be made again from the image `server.json` names now,
    /// its volumes kept, so its sessions are as they were.
    public func wantUpgrade(_ id: String) -> String? { mark(id, Self.upgradeMark) }

    /// The server to be removed: its container, its volumes (and with them
    /// its sessions), its secrets and its folder.
    public func wantRemoved(_ id: String) -> String? { mark(id, Self.removeMark) }

    static let upgradeMark = "upgrade", removeMark = "remove"

    func mark(_ id: String, _ name: String) -> String? {
        guard FileManager.default.fileExists(atPath: ContainerServerSpec.file(folder(id)).path) else { return "No container server \(id)" }
        return FileManager.default.createFile(atPath: folder(id).appendingPathComponent(name).path, contents: nil) ? nil : "\(id) couldn't be marked"
    }

    func marked(_ id: String, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(id).appendingPathComponent(name).path)
    }

    func unmark(_ id: String, _ name: String) {
        try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(name))
    }
}

// Where the Visor family's sockets go once Visor.app is sandboxed (0.67,
// docs/DEVELOPMENT.md, "Sandboxed Visor"): in the app group's container,
// which Visor.app, Visor Agent Utility and Visor Disk Utility all reach
// (`group.com.LoganShire.Visor`), under a folder with a one-letter name,
// `r/`, so every socket's path stays under the 104 bytes a Mac allows one:
//
//   ~/Library/Group Containers/group.com.LoganShire.Visor/r/server.sock
//                                                         r/relay.sock
//                                                         r/driver.sock
//                                                         r/h-<8 hex>.sock
//
// `server.sock` is the server's (the app, local tools, and an SSH client's
// `nc -U`), `relay.sock` and `driver.sock` the Sessions container's, and
// `h-<8 hex>.sock` an agent host's, with a short name of its own.
//
// The binary resolves the group's container (on a Mac, FileManager's
// `containerURL(forSecurityApplicationGroupIdentifier:)`) and gives it
// here; nil, as a build without the group may get, or one whose home is so
// long that a socket in it wouldn't fit, leaves the sockets where they
// were (VisorFolders: the Visor volume's `run/`, else `~/.visor`). In 0.66
// it's used only when asked for (MacPlaces' `groupSockets`), until the
// Developer ID profiles grant the group. Foundation alone: tested on Linux.

import Foundation

public struct VisorPlaces: Equatable, Sendable {
    /// The Visor family's app group: Visor.app, Visor Agent Utility and
    /// Visor Disk Utility (presence, messaging, sockets).
    public static let appGroup = "group.com.LoganShire.Visor"
    /// The group every app of Logan's advertises its installed version in
    /// (UpdateKit's).
    public static let applicationsGroup = "group.com.LoganShire.Applications"

    /// The sockets' folder's name in the group's container: one letter.
    public static let socketFolderName = "r"
    /// The server's socket file's name.
    public static let serverSocketName = VisorFolders.socketName
    /// The Sessions container's relay's and driver link's sockets' names.
    public static let relaySocketName = "relay.sock"
    public static let driverSocketName = "driver.sock"
    /// An agent host's socket's prefix: `h-<8 hex>.sock`.
    public static let hostSocketPrefix = "h-"

    /// The most bytes a socket's path may have on a Mac: `sun_path` is 104
    /// bytes, with the path's closing NUL among them.
    public static let socketPathLimit = 104

    /// The group's container, as the binary resolved it; nil without one.
    public var groupContainer: URL?

    public init(groupContainer: URL?) {
        self.groupContainer = groupContainer
    }

    /// The places with the group's container `resolve` gives for the
    /// group (on a Mac, FileManager's, which is nil for a build that can't
    /// have one).
    public static func locate(resolve: (String) -> URL?) -> VisorPlaces {
        VisorPlaces(groupContainer: resolve(appGroup))
    }

    /// Whether a socket at `path` fits: fewer bytes than the limit, so its
    /// closing NUL does too.
    public static func fits(_ path: String) -> Bool { path.utf8.count < socketPathLimit }

    /// An agent host's socket's name: `h-` and 8 hex digits.
    public static func hostSocketName(_ tag: UInt32) -> String {
        let hex = String(tag, radix: 16)
        return hostSocketPrefix + String(repeating: "0", count: 8 - hex.count) + hex + ".sock"
    }

    /// Every name a socket in the folder may have, the longest among them:
    /// what the folder must leave room for.
    static var longestName: Int {
        [serverSocketName, relaySocketName, driverSocketName, hostSocketName(0)].map(\.utf8.count).max() ?? 0
    }

    /// The sockets' folder, `r/` in the group's container; nil without the
    /// container, or when the longest of its sockets' paths wouldn't fit.
    public var socketFolder: URL? {
        guard let groupContainer else { return nil }
        let folder = groupContainer.appendingPathComponent(Self.socketFolderName, isDirectory: true)
        guard folder.path.utf8.count + 1 + Self.longestName < Self.socketPathLimit else { return nil }
        return folder
    }

    /// The server's socket file there; nil without the folder.
    public var serverSocket: String? { socket(Self.serverSocketName) }
    /// The Sessions container's relay's socket there.
    public var relaySocket: String? { socket(Self.relaySocketName) }
    /// The Sessions container's driver link's socket there.
    public var driverSocket: String? { socket(Self.driverSocketName) }

    /// An agent host's socket there, by its tag.
    public func hostSocket(_ tag: UInt32) -> String? { socket(Self.hostSocketName(tag)) }

    /// The socket `name` in the folder, when it fits.
    private func socket(_ name: String) -> String? {
        guard let path = socketFolder?.appendingPathComponent(name, isDirectory: false).path, Self.fits(path) else { return nil }
        return path
    }
}

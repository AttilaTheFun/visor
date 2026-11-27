// Where Visor on a Mac keeps what is its own: on the Visor volume once it's
// there (docs/containers.md, Visor's volumes), so deleting the three
// volumes after Uninstall… leaves nothing of Visor's behind; else in the
// home folder, as before the volume was:
//
//   on the Visor volume                  without it
//   /Volumes/Visor/Data/                 ~/Library/Application Support/Visor/
//   /Volumes/Visor/Caches/<part>/        ~/Library/Application Support/<bundle id>/<part>/
//   /Volumes/Visor/Logs/                 ~/Library/Logs/
//   /Volumes/Visor/tmp/                  the system's temporary folder
//   /Volumes/Visor/run/server.sock       ~/.visor/server.sock
//   /Volumes/Visor/Containers/           (the Sessions container needs the volume)
//
// The data folder holds the server's sessions' store (server.sqlite),
// settings, push, relay, jobs, images, backups, migrations, super-compact,
// agent-proxy, run/ and hosts/, and volumes.json; the caches are the
// server's and the client's messages.sqlite. What was in the home folder is moved onto the volume
// once, at the server's start (VisorFolderMove). Foundation alone, with no
// disk tool: the same on Linux, where its tests run.

import Foundation

public struct VisorFolders: Equatable, Sendable {
    /// The Visor volume's mount point when one is mounted there; nil when
    /// it isn't (no volume, or not mounted yet).
    public var volume: String?
    /// This user's home folder.
    public var home: String

    public init(volume: String?, home: String) {
        self.volume = volume
        self.home = home
    }

    /// The Visor volume's folders, when it's mounted at /Volumes/Visor, else
    /// the home folder's. `isMountPoint` is the check of a path (tests give
    /// their own).
    public static func locate(home: String = NSHomeDirectory(),
                              isMountPoint: (String) -> Bool = DiskVolumes.isMountPoint) -> VisorFolders {
        let mountPoint = VolumeRole.visor.mountPoint
        return VisorFolders(volume: isMountPoint(mountPoint) ? mountPoint : nil, home: home)
    }

    /// The data folder's name on the volume.
    public static let dataName = "Data"
    /// The container's folder's name on the volume (ContainerLayout's root).
    public static let containersName = "Containers"
    /// The server's socket file's name.
    public static let socketName = "server.sock"

    /// Whether Visor's things are on the volume.
    public var onVolume: Bool { volume != nil }

    private var root: URL? { volume.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    private var homeURL: URL { URL(fileURLWithPath: home, isDirectory: true) }

    /// The server's data folder: `Data/` on the volume, else
    /// `~/Library/Application Support/Visor`.
    public var data: URL { root?.appendingPathComponent(Self.dataName, isDirectory: true) ?? legacyData }

    /// The data folder in the home folder, as it was before the volume.
    public var legacyData: URL {
        homeURL.appendingPathComponent("Library/Application Support/Visor", isDirectory: true)
    }

    /// A cache's folder (`Server`, `Client`): `Caches/<part>` on the volume,
    /// else `~/Library/Application Support/<bundle id>/<part>`.
    public func caches(_ part: String, bundleID: String) -> URL {
        root?.appendingPathComponent("Caches", isDirectory: true).appendingPathComponent(part, isDirectory: true)
            ?? legacyCaches(part, bundleID: bundleID)
    }

    /// A cache's folder in the home folder, as it was before the volume.
    public func legacyCaches(_ part: String, bundleID: String) -> URL {
        homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent(part, isDirectory: true)
    }

    /// The logs' folder: `Logs/` on the volume, else `~/Library/Logs`.
    public var logs: URL { root?.appendingPathComponent("Logs", isDirectory: true) ?? legacyLogs }

    /// The logs' folder in the home folder.
    public var legacyLogs: URL { homeURL.appendingPathComponent("Library/Logs", isDirectory: true) }

    /// A log of Visor's (`Visor-server.log`), in the logs' folder.
    public func log(_ name: String) -> String { logs.appendingPathComponent(name, isDirectory: false).path }

    /// Staging for what's made to be handed over and removed (an export
    /// before it's saved): `tmp/` on the volume, emptied at the app's start;
    /// nil without the volume (the system's temporary folder, then).
    public var temporary: URL? { root?.appendingPathComponent("tmp", isDirectory: true) }

    /// The server's socket file: `run/server.sock` on the volume, else nil
    /// (VisorServer's own, `~/.visor/server.sock`).
    public var socket: String? { root?.appendingPathComponent("run", isDirectory: true).appendingPathComponent(Self.socketName).path }

    /// `~/.visor`, where the socket file was before the volume: kept for one
    /// release (0.65) as a link to the volume's, for an SSH client of 0.64
    /// (`nc -U ~/.visor/server.sock`), then removed.
    public var legacySocketFolder: URL { homeURL.appendingPathComponent(".visor", isDirectory: true) }

    /// The container's folder: `Containers/` on the volume; nil without it.
    public var containers: URL? { root?.appendingPathComponent(Self.containersName, isDirectory: true) }

    /// The Visor's logs in the home folder that a move takes onto the volume.
    public static let logNames = ["Visor-server.log", "Visor-agent-proxy.log", "Visor-egress.log"]
}

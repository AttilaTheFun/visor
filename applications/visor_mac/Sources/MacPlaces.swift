// Where Visor on the Mac keeps what is its own: the server's secrets and the
// client's under two keychain services, and the rest on the Visor volume
// once it's there (VisorFolders: `/Volumes/Visor/Data`, `Caches/Server` and
// `Caches/Client`, `Logs`, `tmp`, `run/server.sock`), else in the home
// folder as before (Application Support/Visor, the caches under
// Application Support/<bundle id>, ~/Library/Logs). Settled once per
// process, before anything opens them (`settle`): the process about to run
// the server moves what was in the home folder onto the volume first
// (VisorFolderMove), and once the data folder has moved, a later start
// waits a minute for the volume to be mounted (at login it can come after
// the server agent) rather than start afresh in the home folder.

import DiskVolumes
import Foundation
import Synchronization
import VisorServerPOSIX

enum MacPlaces {
    /// This app's bundle id, the stem of its services and its folder.
    static var own: String { Bundle.main.bundleIdentifier ?? "com.LoganShire.Visor" }
    /// The keychain service of the server's secrets: apart from the
    /// client's.
    static var serverService: String { own + ".server" }
    /// The keychain service of the client's: the app's own.
    static var clientService: String { own }

    /// The default set once the data folder is on the Visor volume: a start
    /// without the volume then waits for it.
    static let onVolumeKey = "VisorDataOnVolume"

    /// What `settle` found: the folders, and the data folder in use.
    private static let settled = Mutex<(folders: VisorFolders, data: URL)?>(nil)

    /// Visor's folders, as settled (found now if they haven't been).
    static var folders: VisorFolders { settled.withLock { $0?.folders } ?? VisorFolders.locate() }

    /// The server's data folder, as settled: the Visor volume's once
    /// what was in the home folder has moved there.
    static var data: URL { settled.withLock { $0?.data } ?? VisorFolderMove.dataFolder(folders) }

    /// The folders found and, in the process that will run the server
    /// (`runsServer`), the home folder's data, server cache and logs moved
    /// onto the Visor volume; in the app (`client`), its own cache moved,
    /// and the volume's tmp/ emptied. Before the server's platform is
    /// given, and before either cache is opened. Whether the Visor volume
    /// that holds the data is missing (the server agent then ends, for
    /// launchd to start it again, rather than serve from an empty folder).
    @discardableResult
    static func settle(runsServer: Bool, client: Bool, log: @escaping @Sendable (String) -> Void) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: onVolumeKey), !VisorFolders.locate().onVolume {
            log("Visor's data is on the Visor volume, which isn't mounted yet: waiting up to a minute for it")
            for _ in 0..<60 where !VisorFolders.locate().onVolume { Thread.sleep(forTimeInterval: 1) }
        }
        let folders = VisorFolders.locate()
        let move = VisorFolderMove(folders: folders, answers: { POSIXUnixSocket.answers($0) }, log: log)
        if runsServer {
            move.moveData()
            move.moveCaches("Server", bundleID: own)
            move.moveLogs()
        }
        if client {
            move.moveCaches("Client", bundleID: own)
            if let temporary = folders.temporary { emptied(temporary) }
        }
        let data = VisorFolderMove.dataFolder(folders)
        if folders.onVolume, data == folders.data { defaults.set(true, forKey: onVolumeKey) }
        let missing = !folders.onVolume && defaults.bool(forKey: onVolumeKey)
        if missing {
            log("the Visor volume isn't mounted at \(VolumeRole.visor.mountPoint): Visor's data there can't be reached")
        }
        settled.withLock { $0 = (folders, data) }
        return missing
    }

    // MARK: The app group's container (0.66, behind a setting)

    /// The default that puts the sockets in the app group's container
    /// (VisorPlaces: `r/server.sock`, the Sessions container's relay and
    /// driver sockets, the agents' hosts' `h-<8 hex>.sock`: docs/sandboxed.md).
    /// Off unless set (`defaults write com.LoganShire.Visor
    /// VisorGroupSockets -bool true`, or VISOR_GROUP_SOCKETS=1 in the
    /// environment) until the Developer ID profiles grant the group.
    static let groupSocketsKey = "VisorGroupSockets"

    /// Whether the sockets go in the app group's container.
    static var groupSockets: Bool {
        if ProcessInfo.processInfo.environment["VISOR_GROUP_SOCKETS"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: groupSocketsKey)
    }

    /// The app group's places when the sockets go there and the group has
    /// a container where every socket fits; nil otherwise (a build without
    /// the group may have none), when they stay where they were.
    static var groupPlaces: VisorPlaces? {
        guard groupSockets else { return nil }
        let places = VisorPlaces.locate { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        return places.socketFolder == nil ? nil : places
    }

    /// The server's socket file: the app group's container's when the
    /// sockets go there, else the Visor volume's, else nil (VisorServer's
    /// own, `~/.visor/server.sock`).
    static var socket: String? { groupPlaces?.serverSocket ?? folders.socket }

    /// Where the socket file was, linked to the group's for a release: the
    /// Visor volume's (`~/.visor`'s is VisorServer's own to link).
    static var socketLinks: [String] {
        guard groupPlaces != nil, let volume = folders.socket else { return [] }
        return [volume]
    }

    /// A cache's folder (`Server`, `Client`): on the Visor volume, else
    /// this app's folder of Application Support.
    static func folder(_ part: String) -> URL { folders.caches(part, bundleID: own) }

    /// A log of Visor's by name, in its logs' folder.
    static func log(_ name: String) -> String { folders.log(name) }

    /// The folder's contents removed, the folder kept (this user's alone).
    private static func emptied(_ folder: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

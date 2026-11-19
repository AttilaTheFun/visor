// How Visor finds its two volumes, read-only.

import Foundation

/// Visor's two volumes as Visor's server finds them: volumes.json (Visor
/// Disk Utility's) for what they are, and the mount points themselves for
/// whether they're there. Nothing here changes a disk or runs a tool.
public struct DiskVolumes: Equatable, Sendable {
    public var sessions: LocatedVolume
    public var containers: LocatedVolume
    /// volumes.json as read; nil when there's none, or it's unreadable or of
    /// a later format.
    public var status: VolumesStatus?

    public init(sessions: LocatedVolume, containers: LocatedVolume, status: VolumesStatus?) {
        self.sessions = sessions
        self.containers = containers
        self.status = status
    }

    public subscript(role: VolumeRole) -> LocatedVolume {
        switch role {
        case .sessions: sessions
        case .containers: containers
        }
    }

    /// Finds both, from volumes.json in Visor's data folder and the mount
    /// points. `isMountPoint` is the check of a path (tests give their own).
    public static func locate(dataDirectory: URL,
                              isMountPoint: (String) -> Bool = DiskVolumes.isMountPoint) -> DiskVolumes {
        let status = readStatus(at: VolumesStatus.url(inDataDirectory: dataDirectory))
        func located(_ role: VolumeRole) -> LocatedVolume {
            let record = status?.record(for: role)
            let path = record?.path ?? role.mountPoint
            return LocatedVolume(role: role, path: path, isMounted: isMountPoint(path), record: record)
        }
        return DiskVolumes(sessions: located(.sessions), containers: located(.containers), status: status)
    }

    /// volumes.json, if it's there and of a format this reads.
    public static func readStatus(at url: URL) -> VolumesStatus? {
        guard let data = try? Data(contentsOf: url),
              let status = try? VolumesStatus.decoded(from: data),
              status.version <= VolumesStatus.currentVersion else { return nil }
        return status
    }

    /// Whether a volume is mounted at the path: it's a folder on another
    /// device than its parent's (or it's /).
    public static func isMountPoint(_ path: String) -> Bool {
        let files = FileManager.default
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, let own = device(of: path), let parents = device(of: parent) else { return path == "/" }
        return own != parents
    }

    /// The device a path is on (stat's st_dev), however Foundation gives it.
    private static func device(of path: String) -> UInt64? {
        guard let value = try? FileManager.default.attributesOfItem(atPath: path)[.systemNumber] else { return nil }
        if let number = value as? UInt64 { return number }
        if let number = value as? Int { return UInt64(bitPattern: Int64(number)) }
        if let number = value as? NSNumber { return number.uint64Value }
        return nil
    }
}

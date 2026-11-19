// The diskutil commands Visor Disk Utility runs as an administrator.

/// One `diskutil` command line. Only two kinds are ever made: adding a
/// volume, and deleting Containers (VolumeGuard checks both again before
/// anything runs).
public struct DiskCommand: Equatable, Sendable, CustomStringConvertible {
    /// diskutil, by its full path: never one found on a PATH.
    public static let diskutil = "/usr/sbin/diskutil"

    /// Its arguments, after diskutil's own path.
    public var arguments: [String]

    /// A command as given. Nothing runs it but DiskTool, after VolumeGuard
    /// has passed it.
    public init(arguments: [String]) { self.arguments = arguments }

    /// The whole command line, diskutil first.
    public var argv: [String] { [Self.diskutil] + arguments }

    public var description: String { (["diskutil"] + arguments).joined(separator: " ") }

    /// `diskutil apfs addVolume <container> "Case-sensitive APFS" <name>
    /// [-reserve <bytes>b] [-quota <bytes>b]`: mounted at /Volumes/<name>.
    public static func addVolume(_ role: VolumeRole, container: String, reserve: Int64, quota: Int64) throws -> DiskCommand {
        guard reserve >= 0, quota >= 0 else { throw DiskVolumesError.blocked("A reserve or quota can't be negative.") }
        if quota > 0, reserve > quota {
            throw DiskVolumesError.blocked("\(role.volumeName)'s reserve (\(ByteSize.describe(reserve))) is more than its quota (\(ByteSize.describe(quota))).")
        }
        var arguments = ["apfs", "addVolume", container, role.personality, role.volumeName]
        if reserve > 0 { arguments += ["-reserve", ByteSize.argument(reserve)] }
        if quota > 0 { arguments += ["-quota", ByteSize.argument(quota)] }
        return DiskCommand(arguments: arguments)
    }

    /// `diskutil apfs deleteVolume <disk>`, for Containers alone: Sessions
    /// throws.
    public static func deleteVolume(_ role: VolumeRole, device: String) throws -> DiskCommand {
        guard role.isErasable else { throw DiskVolumesError.sessionsNeverErased("diskutil apfs deleteVolume \(device)") }
        return DiskCommand(arguments: ["apfs", "deleteVolume", device])
    }
}

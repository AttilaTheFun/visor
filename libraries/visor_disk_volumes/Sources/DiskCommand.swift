// The diskutil commands Visor Disk Utility runs as an administrator.

import Foundation

/// One command line run as an administrator. Only three kinds are ever
/// made: adding a volume, deleting one of Visor's, and turning Spotlight off
/// on the Visor volume (VolumeGuard checks each again before anything runs,
/// and passes a delete only of a role asked for, and Spotlight's only on
/// Visor's own).
public struct DiskCommand: Equatable, Sendable, CustomStringConvertible {
    /// diskutil, by its full path: never one found on a PATH.
    public static let diskutil = "/usr/sbin/diskutil"
    /// Spotlight's tool, by its full path.
    public static let mdutil = "/usr/bin/mdutil"

    /// The program, by its full path: diskutil unless said.
    public var program: String
    /// Its arguments, after the program's own path.
    public var arguments: [String]

    /// A command as given. Nothing runs it but DiskTool, after VolumeGuard
    /// has passed it.
    public init(program: String = DiskCommand.diskutil, arguments: [String]) {
        self.program = program
        self.arguments = arguments
    }

    /// The whole command line, the program first.
    public var argv: [String] { [program] + arguments }

    public var description: String { ([(program as NSString).lastPathComponent] + arguments).joined(separator: " ") }

    /// `mdutil -i off <mount point>`: Spotlight's index of the Visor volume
    /// off, as Nimbus turns it off on its own (its data, caches, logs and
    /// container are nothing to search). Sessions and Sources stay indexed.
    public static func spotlightOff(_ role: VolumeRole) throws -> DiskCommand {
        guard role == .visor else { throw DiskVolumesError.blocked("Spotlight is turned off on the Visor volume alone.") }
        return DiskCommand(program: mdutil, arguments: ["-i", "off", role.mountPoint])
    }

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

    /// `diskutil apfs deleteVolume <volume UUID>`: by its APFS volume UUID,
    /// never its disk (`disk3s8`): disk numbers can change between
    /// VolumeGuard's look and the command running as root, a UUID can't.
    /// Made only for Uninstall…, when the volumes' deletion is asked for;
    /// VolumeGuard refuses it otherwise.
    public static func deleteVolume(_ role: VolumeRole, uuid: String) throws -> DiskCommand {
        guard isVolumeUUID(uuid) else {
            throw DiskVolumesError.blocked("\(role.volumeName) has no APFS volume UUID (\"\(uuid)\"): it's deleted by its UUID alone.")
        }
        return DiskCommand(arguments: ["apfs", "deleteVolume", uuid])
    }

    /// Whether a target is a volume UUID (`4EF85269-E4B1-4058-A1FA-E9240A971CC9`),
    /// as diskutil lists them, not a disk, a name or a path.
    public static func isVolumeUUID(_ target: String) -> Bool {
        target.count == 36 && UUID(uuidString: target) != nil
    }
}

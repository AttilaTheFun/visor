// The diskutil commands Visor Disk Utility runs as an administrator.

import Foundation

/// One command line run as an administrator. Only these are ever made:
/// adding a volume, giving a volume just made to the person (chown, chmod),
/// and turning Spotlight off on the Visor volume (VolumeGuard checks each
/// again before anything runs, and passes Spotlight's only on Visor's own,
/// and an owner only of a volume made in the same run, or one the card's
/// Fix names). None deletes, erases or reformats a volume.
public struct DiskCommand: Equatable, Sendable, CustomStringConvertible {
    /// diskutil, by its full path: never one found on a PATH.
    public static let diskutil = "/usr/sbin/diskutil"
    /// Spotlight's tool, by its full path.
    public static let mdutil = "/usr/bin/mdutil"
    /// chown and chmod, by their full paths.
    public static let chown = "/usr/sbin/chown"
    public static let chmod = "/bin/chmod"

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

    /// `chown <user>:staff <mount point>` and `chmod 775 <mount point>`: a
    /// volume made as an administrator is root's at its root, where Visor
    /// can't write (its data folder, its socket, the sessions' folders), so
    /// it's given to the person who made it, as Nimbus gives its own, in the
    /// same prompt.
    public static func ownership(_ role: VolumeRole, user: String) throws -> [DiskCommand] {
        guard isUserName(user) else { throw DiskVolumesError.blocked("\(user) isn't a user's name.") }
        return [DiskCommand(program: chown, arguments: [user + ":staff", role.mountPoint]),
                DiskCommand(program: chmod, arguments: ["775", role.mountPoint])]
    }

    /// Whether `name` is a short user name: letters, digits, `.`, `_` and
    /// `-`, not starting with `-`.
    public static func isUserName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix("-")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

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

    /// Whether a target is a volume UUID (`4EF85269-E4B1-4058-A1FA-E9240A971CC9`),
    /// as diskutil lists them, not a disk, a name or a path.
    public static func isVolumeUUID(_ target: String) -> Bool {
        target.count == 36 && UUID(uuidString: target) != nil
    }
}

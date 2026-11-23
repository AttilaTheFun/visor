// One path as a copy's check sees it: its kind, data's size and times, and
// everything a copy must keep besides its data (mode, owner, group, flags,
// extended attributes, ACL, hard links).

/// What `lstat` and friends say of a path (never following a link).
public struct FileInspection: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case directory = "D"
        case regular = "F"
        case link = "L"
        case socket = "S"
        /// A FIFO, a device, or anything else.
        case other = "O"
    }

    public var kind: Kind
    /// What an `.other` is (`fifo`, `characterSpecial`…).
    public var typeName: String
    public var size: Int64
    /// The bytes it takes on disk (`st_blocks` × 512): what a copy of it
    /// writes, a small file's block among them.
    public var allocated: Int64
    /// The modification and status-change times as text (exactly as read);
    /// nil when unknown (Foundation has no status-change time).
    public var modified: String
    public var changed: String?
    /// The permission bits, setuid, setgid and sticky among them (0o7777).
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32
    /// `st_flags` as read (0 where there are none, as on Linux).
    public var flags: UInt32
    public var inode: UInt64
    public var linkCount: UInt64
    /// A device's number (`st_rdev`).
    public var rdev: UInt64
    /// The sha256 of the extended attributes' names and values, sorted by
    /// name; "-" with none; `unreadable` when they couldn't be read (EPERM,
    /// EACCES…: a copy as the person can't be checked against them); nil
    /// when this inspector doesn't read them (Foundation's).
    public var xattrs: String?
    /// The sha256 of the ACL's text; "-" with none; `unreadable` when it
    /// couldn't be read; nil when this inspector doesn't read it.
    public var acl: String?

    /// What an inspector says of extended attributes or an ACL it tried and
    /// failed to read.
    public static let unreadable = "?"
    /// A link's target.
    public var linkTarget: String?
    /// Whether the person can read it (a folder: read and search).
    public var readable: Bool

    public init(kind: Kind, typeName: String = "", size: Int64 = 0, allocated: Int64? = nil, modified: String = "", changed: String? = nil, mode: UInt32 = 0,
                uid: UInt32 = 0, gid: UInt32 = 0, flags: UInt32 = 0, inode: UInt64 = 0, linkCount: UInt64 = 1, rdev: UInt64 = 0,
                xattrs: String? = nil, acl: String? = nil, linkTarget: String? = nil, readable: Bool = true) {
        self.kind = kind
        self.typeName = typeName
        self.size = size
        self.allocated = allocated ?? Self.blocks(size)
        self.modified = modified
        self.changed = changed
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.flags = flags
        self.inode = inode
        self.linkCount = linkCount
        self.rdev = rdev
        self.xattrs = xattrs
        self.acl = acl
        self.linkTarget = linkTarget
        self.readable = readable
    }

    /// A size rounded up to whole 4 KiB blocks (APFS's), where the blocks
    /// themselves can't be read (Foundation).
    public static func blocks(_ size: Int64) -> Int64 {
        let block: Int64 = 4096
        return (max(0, size) + block - 1) / block * block
    }

    // The BSD file flags (sys/stat.h) a copy is held to. Those the system
    // sets for itself (compressed, tracked, datavault, firmlink, dataless)
    // aren't compared: a copy needn't, or can't, have them.
    public static let userFlags: UInt32 = 0x0000_0001 | 0x0000_0002 | 0x0000_0004 | 0x0000_0008 | 0x0000_8000
    /// The super-user's flags (archived, immutable, append, restricted,
    /// no-unlink): the person can't set them, so a file with one can't be
    /// copied as it is without root.
    public static let systemFlags: UInt32 = 0x0001_0000 | 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000
    /// A dataless file (its data in the cloud, not here).
    public static let datalessFlag: UInt32 = 0x4000_0000

    /// The flags compared between a file and its copy.
    public var comparedFlags: UInt32 { flags & (Self.userFlags | Self.systemFlags) }

    /// What a copy must keep of it besides its data, for a manifest's line:
    /// `m=0644 u=501 g=20 f=0 x=<sha> a=<sha>`.
    public var metadata: String {
        "m=\(String(mode & 0o7777, radix: 8)) u=\(uid) g=\(gid) f=\(String(comparedFlags, radix: 16)) x=\(xattrs ?? "?") a=\(acl ?? "?")"
    }
}

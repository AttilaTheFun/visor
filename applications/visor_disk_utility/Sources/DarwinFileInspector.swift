// A path's metadata as the Mac has it, for a conversion's check
// (FileInspecting): lstat's mode, owner, group, flags, inode, link count,
// device and times (to the nanosecond), its extended attributes (names and
// values) and its ACL's text. Never following a link.

import Darwin
import DiskVolumes
import Foundation

struct DarwinFileInspector: FileInspecting {
    func inspect(_ path: String) throws -> FileInspection {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw DiskVolumesError.failed("\(path) couldn't be read: \(String(cString: strerror(errno)))")
        }
        let format = info.st_mode & S_IFMT
        let kind: FileInspection.Kind = switch format {
        case S_IFDIR: .directory
        case S_IFREG: .regular
        case S_IFLNK: .link
        case S_IFSOCK: .socket
        default: .other
        }
        let typeName = switch format {
        case S_IFIFO: "fifo"
        case S_IFCHR: "characterSpecial"
        case S_IFBLK: "blockSpecial"
        default: "\(format)"
        }
        var inspection = FileInspection(
            kind: kind, typeName: typeName, size: Int64(info.st_size),
            modified: "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)",
            changed: "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)",
            mode: UInt32(info.st_mode & 0o7777), uid: info.st_uid, gid: info.st_gid, flags: info.st_flags,
            inode: info.st_ino, linkCount: UInt64(info.st_nlink), rdev: kind == .other ? UInt64(UInt32(bitPattern: info.st_rdev)) : 0,
            xattrs: try Self.xattrs(path), acl: Self.acl(path))
        switch kind {
        case .link:
            inspection.linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        case .directory:
            inspection.readable = access(path, R_OK | X_OK) == 0
        case .regular:
            inspection.readable = access(path, R_OK) == 0
        case .socket, .other:
            break
        }
        return inspection
    }

    /// The sha256 of the extended attributes' names and values, sorted by
    /// name ("-" with none).
    static func xattrs(_ path: String) throws -> String {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else {
            if size < 0, errno != ENOTSUP, errno != EPERM, errno != EACCES {
                throw DiskVolumesError.failed("\(path)'s extended attributes couldn't be listed: \(String(cString: strerror(errno)))")
            }
            return size == 0 ? "-" : "?"
        }
        var names = [CChar](repeating: 0, count: size)
        let listed = listxattr(path, &names, size, XATTR_NOFOLLOW)
        guard listed >= 0 else { return "?" }
        let all = names.prefix(listed).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var data = Data()
        for name in all.sorted() {
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            var value = [UInt8](repeating: 0, count: max(0, length))
            let read = length > 0 ? getxattr(path, name, &value, length, 0, XATTR_NOFOLLOW) : 0
            guard read >= 0 else { return "?" }
            data.append(Data(name.utf8))
            data.append(0)
            data.append(Data("\(read)".utf8))
            data.append(0)
            data.append(contentsOf: value.prefix(read))
        }
        return VolumeManifest.digest(data)
    }

    /// The sha256 of the ACL's text ("-" with none).
    static func acl(_ path: String) -> String {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return "-" }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else { return "?" }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return VolumeManifest.digest(Data(bytes: text, count: length))
    }
}

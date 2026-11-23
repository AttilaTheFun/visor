// A path's metadata as Foundation reads it, on Linux as on a Mac: kind,
// size, modification time, mode, owner, group, inode, link count, device.
// No flags, status-change time, extended attributes or ACL (nil: unknown),
// which the Mac's own inspector adds.

import Foundation

public struct FoundationFileInspector: FileInspecting {
    public init() {}

    public func inspect(_ path: String) throws -> FileInspection {
        let files = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try files.attributesOfItem(atPath: path)
        } catch {
            throw DiskVolumesError.failed("\(path) couldn't be read: \(error.localizedDescription)")
        }
        func number(_ key: FileAttributeKey) -> UInt64 {
            if let value = attributes[key] as? NSNumber { return value.uint64Value }
            if let value = attributes[key] as? UInt64 { return value }
            if let value = attributes[key] as? Int { return UInt64(truncatingIfNeeded: value) }
            if let value = attributes[key] as? UInt32 { return UInt64(value) }
            return 0
        }
        let type = attributes[.type] as? FileAttributeType
        let kind: FileInspection.Kind = switch type {
        case FileAttributeType.typeDirectory?: .directory
        case FileAttributeType.typeRegular?: .regular
        case FileAttributeType.typeSymbolicLink?: .link
        case FileAttributeType.typeSocket?: .socket
        default: .other
        }
        var inspection = FileInspection(
            kind: kind, typeName: type?.rawValue ?? "unknown", size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) } ?? "?",
            mode: UInt32(truncatingIfNeeded: number(.posixPermissions)), uid: UInt32(truncatingIfNeeded: number(.ownerAccountID)),
            gid: UInt32(truncatingIfNeeded: number(.groupOwnerAccountID)), inode: number(.systemFileNumber),
            linkCount: max(1, number(.referenceCount)), rdev: kind == .other ? number(.deviceIdentifier) : 0)
        switch kind {
        case .link:
            inspection.linkTarget = try? files.destinationOfSymbolicLink(atPath: path)
        case .directory:
            inspection.readable = files.isReadableFile(atPath: path) && files.isExecutableFile(atPath: path)
        case .regular:
            inspection.readable = files.isReadableFile(atPath: path)
        case .socket, .other:
            break
        }
        return inspection
    }
}

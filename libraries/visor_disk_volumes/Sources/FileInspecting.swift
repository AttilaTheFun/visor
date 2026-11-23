// How a copy's check reads a path's metadata: Foundation's, portable (no
// flags, extended attributes or ACL), or the Mac's (Visor Disk Utility's
// DarwinFileInspector: lstat, listxattr, acl_get_link_np).

public protocol FileInspecting: Sendable {
    /// The path itself, a link never followed.
    func inspect(_ path: String) throws -> FileInspection
}

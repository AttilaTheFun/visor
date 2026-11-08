import Foundation

/// The folders a container's computer shares with it (HostDetails.
/// sharedFolders), as its mount table has them: each one mounted writable
/// from the computer's own disk (Apple's container and Docker Desktop on a
/// Mac share over virtiofs, 9p or gRPC FUSE), at its mount point. A
/// read-only one (Visor's own programs, `/opt/visor-server`) is no place
/// for a session's work.
enum LinuxMounts {
    static let sharing: Set<String> = ["virtiofs", "9p", "fuse.grpcfuse", "fakeowner"]

    /// Those of this process's mount table; nil when it can't be read or
    /// names none.
    static func shared() -> [String]? {
        guard let table = try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8) else { return nil }
        let found = shared(mountinfo: table)
        return found.isEmpty ? nil : found
    }

    /// From a mount table (proc(5)'s mountinfo: the mount point fifth, its
    /// options sixth, then after `-` the file system's type).
    static func shared(mountinfo: String) -> [String] {
        mountinfo.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count > 6, let dash = fields.firstIndex(of: "-"), dash + 1 < fields.count,
                  sharing.contains(fields[dash + 1]), !fields[5].split(separator: ",").contains("ro") else { return nil }
            return unescaped(fields[4])
        }
    }

    /// A mount point as the table writes it: a space, tab, newline or
    /// backslash as three octal digits after a backslash.
    static func unescaped(_ field: String) -> String {
        var out = ""
        var rest = Substring(field)
        while let first = rest.first {
            if first == "\\", rest.count >= 4, let code = UInt8(rest.dropFirst().prefix(3), radix: 8) {
                out.append(Character(UnicodeScalar(code)))
                rest = rest.dropFirst(4)
            } else {
                out.append(first)
                rest = rest.dropFirst()
            }
        }
        return out
    }
}

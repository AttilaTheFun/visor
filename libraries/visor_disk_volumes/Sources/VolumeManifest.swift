// What's on a volume, path by path, so a copy can be checked against its
// source (`.content`): every regular file's sha256, every symbolic link's
// target, every folder, and of each its mode, owner, group, flags,
// extended attributes and ACL; the hard links that share a file, by path;
// FIFOs and devices by type, mode and device number. Or, cheap
// (`.listing`), every path's size and modification and status-change
// times: copy-staged takes it before and after the copy, and Swap In takes
// it again, as root, just before the first rename. The system's own folders
// at the root are left out, as they're never copied, and so is the
// conversion's marker.

import Crypto
import Foundation

public struct VolumeManifest: Equatable, Sendable {
    /// What each line says of a path.
    public enum Kind: Sendable {
        /// Content and what a copy must keep besides it.
        case content
        /// Size and times.
        case listing
    }

    /// The folders macOS keeps at a volume's root for itself: never copied,
    /// never compared.
    public static let systemFolders: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
    ]

    /// What's left out at the root: the system's folders and the marker.
    public static let leftOutAtRoot: Set<String> = systemFolders.union([ConversionMarker.fileName])

    /// One line a path, sorted by path, then one a hard-link group:
    /// `D <meta> <path>`, `F <sha256> <meta> <path>`, `L <target> u=<uid>
    /// g=<gid> <path>`, `O <type> <meta> r=<rdev> <path>`, `H <paths, by
    /// tab>`; or, as a listing, `<kind> <size> <mtime> <ctime> <path>`. A
    /// path's `\`, tab and newline escaped.
    public var lines: [String]
    public var files: Int
    public var links: Int
    public var directories: Int
    /// The groups of paths that are one file (hard links), each sorted.
    public var hardLinks: [[String]]
    /// Sockets, left out (a socket file is no data: nothing copies one, and
    /// it means nothing once its server has gone), by path.
    public var sockets: [String]

    /// The sha256 of the lines, each ended by a newline.
    public var sha256: String { Self.hex(SHA256.hash(data: Data(text.utf8))) }

    /// The lines as one text.
    public var text: String { lines.map { $0 + "\n" }.joined() }

    /// The manifest of everything under `root` (a volume's mount point, or
    /// any folder), symbolic links never followed.
    public static func make(of root: String, _ kind: Kind, inspector: some FileInspecting = FoundationFileInspector()) throws -> VolumeManifest {
        var entries: [(path: String, line: String)] = []
        var manifest = VolumeManifest(lines: [], files: 0, links: 0, directories: 0, hardLinks: [], sockets: [])
        var shared: [UInt64: [String]] = [:]
        try VolumeTree.walk(root, inspector: inspector) { path, file in
            let escaped = escape(path)
            if kind == .listing {
                if file.kind != .socket {
                    entries.append((path, "\(file.kind.rawValue) \(file.size) \(file.modified) \(file.changed ?? "?") \(escaped)"))
                }
                return true
            }
            switch file.kind {
            case .directory:
                manifest.directories += 1
                entries.append((path, "D \(file.metadata) \(escaped)"))
            case .regular:
                manifest.files += 1
                let full = (root as NSString).appendingPathComponent(path)
                entries.append((path, "F \(try hash(file: full)) \(file.metadata) \(escaped)"))
                if file.linkCount > 1 { shared[file.inode, default: []].append(path) }
            case .link:
                manifest.links += 1
                entries.append((path, "L \(escape(file.linkTarget ?? "?")) u=\(file.uid) g=\(file.gid) \(escaped)"))
            case .socket:
                manifest.sockets.append(path)
            case .other:
                entries.append((path, "O \(file.typeName) \(file.metadata) r=\(file.rdev) \(escaped)"))
            }
            return true
        }
        manifest.lines = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }.map(\.line)
        manifest.hardLinks = shared.values.filter { $0.count > 1 }
            .map { $0.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }
            .sorted { $0[0].utf8.lexicographicallyPrecedes($1[0].utf8) }
        manifest.lines += manifest.hardLinks.map { "H " + $0.map(escape).joined(separator: "\t") }
        return manifest
    }

    /// The first lines that differ between this (the source) and `other`
    /// (the copy), at most `limit`: `- <line>` only here, `+ <line>` only
    /// there.
    public func differences(from other: VolumeManifest, limit: Int = 10) -> [String] {
        let mine = Set(lines), theirs = Set(other.lines)
        let missing = lines.filter { !theirs.contains($0) }.map { "- " + $0 }
        let extra = other.lines.filter { !mine.contains($0) }.map { "+ " + $0 }
        return Array((missing + extra).prefix(limit))
    }

    /// A file's sha256, read a megabyte at a time.
    public static func hash(file path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw DiskVolumesError.failed("\(path) couldn't be opened to be checked.")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw DiskVolumesError.failed("\(path) couldn't be read to be checked: \(error.localizedDescription)")
        }
        return hex(hasher.finalize())
    }

    /// The sha256 of some bytes, as hex.
    public static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// A path as a line holds it: `\` as `\\`, a tab as `\t`, a newline as `\n`.
    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef")
        var text = ""
        for byte in digest {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }
}

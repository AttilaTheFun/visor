// What's on a volume, path by path, so a copy can be checked against its
// source: every regular file's sha256, every symbolic link's target and
// every folder (`.content`), or every path's size and modification time
// (`.listing`, cheap: Swap In takes it again to see nothing changed since
// the copy). The system's own folders at the root are left out, as they're
// never copied, and so is the conversion's marker.

import Crypto
import Foundation

public struct VolumeManifest: Equatable, Sendable {
    /// What each line says of a path.
    public enum Kind: Sendable {
        /// Files by their sha256, links by their targets, folders by name.
        case content
        /// Files by size and modification time, links by target and time,
        /// folders by time.
        case listing
    }

    /// The folders macOS keeps at a volume's root for itself: never copied,
    /// never compared.
    public static let systemFolders: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
    ]

    /// What's left out at the root: the system's folders and the marker.
    public static let leftOutAtRoot: Set<String> = systemFolders.union([ConversionMarker.fileName])

    /// One line a path, sorted by path: `F <sha256> <path>`, `L <target>
    /// <path>`, `D <path>`, `O <type> <path>` (anything else but a socket);
    /// a path's `\` and newline escaped.
    public var lines: [String]
    public var files: Int
    public var links: Int
    public var directories: Int
    /// Sockets, left out (a socket file is no data: nothing copies one, and
    /// it means nothing once its server has gone), by path.
    public var sockets: [String]

    /// The sha256 of the lines, each ended by a newline.
    public var sha256: String { Self.hex(SHA256.hash(data: Data(text.utf8))) }

    /// The lines as one text.
    public var text: String { lines.map { $0 + "\n" }.joined() }

    /// The manifest of everything under `root` (a volume's mount point, or
    /// any folder), symbolic links never followed.
    public static func make(of root: String, _ kind: Kind) throws -> VolumeManifest {
        var entries: [(path: String, line: String)] = []
        var manifest = VolumeManifest(lines: [], files: 0, links: 0, directories: 0, sockets: [])
        try walk(root: root, relative: "", kind: kind, into: &entries, manifest: &manifest)
        manifest.lines = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }.map(\.line)
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

    private static func walk(root: String, relative: String, kind: Kind, into entries: inout [(path: String, line: String)],
                             manifest: inout VolumeManifest) throws {
        let files = FileManager.default
        let folder = relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
        let names: [String]
        do {
            names = try files.contentsOfDirectory(atPath: folder)
        } catch {
            throw DiskVolumesError.failed("\(folder) couldn't be read: \(error.localizedDescription)")
        }
        for name in names {
            if relative.isEmpty, leftOutAtRoot.contains(name) { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            let full = (root as NSString).appendingPathComponent(path)
            let attributes: [FileAttributeKey: Any]
            do {
                // Of the path itself: a link is never followed (lstat).
                attributes = try files.attributesOfItem(atPath: full)
            } catch {
                throw DiskVolumesError.failed("\(full) couldn't be read: \(error.localizedDescription)")
            }
            let type = attributes[.type] as? FileAttributeType
            let escaped = escape(path)
            let time = (attributes[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) } ?? "?"
            switch type {
            case FileAttributeType.typeDirectory?:
                manifest.directories += 1
                entries.append((path, kind == .content ? "D \(escaped)" : "D \(time) \(escaped)"))
                try walk(root: root, relative: path, kind: kind, into: &entries, manifest: &manifest)
            case FileAttributeType.typeRegular?:
                manifest.files += 1
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                entries.append((path, kind == .content ? "F \(try hash(file: full)) \(escaped)" : "F \(size) \(time) \(escaped)"))
            case FileAttributeType.typeSymbolicLink?:
                manifest.links += 1
                let target: String
                do {
                    target = try files.destinationOfSymbolicLink(atPath: full)
                } catch {
                    throw DiskVolumesError.failed("\(full)'s link couldn't be read: \(error.localizedDescription)")
                }
                entries.append((path, kind == .content ? "L \(escape(target)) \(escaped)" : "L \(escape(target)) \(time) \(escaped)"))
            case FileAttributeType.typeSocket?:
                manifest.sockets.append(path)
            default:
                entries.append((path, "O \(type?.rawValue ?? "unknown") \(escaped)"))
            }
        }
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

    /// A path as a line holds it: `\` as `\\`, a newline as `\n`.
    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
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

// Visor's Linux programs for the container: Contents/Resources/Linux
// (visor-server, with visor-agent-host and relay-client links to it, and
// agent_protocol's agent-wrapper, a static program of its own),
// copied to the Containers volume's tools/<visor version>/ and mounted
// read-only at /opt/visor/bin. A share of the app bundle itself would go
// stale when the app is updated in place.
//
// The link rule (docs/containers.md): each entry is a regular executable,
// or a relative link whose target has no `/` and is a regular executable
// in the same folder. Anything else (a dangling, absolute or escaping link,
// a link to a link, a folder) is refused, and the container shows "no
// egress": a relay-client that doesn't resolve inside the mount leaves it
// with no way out.

import Foundation

public enum ToolsFolder {
    /// What the container runs from the folder: its relay to agent-proxy,
    /// the agents' host, the server they're names of, and each session's
    /// agent-wrapper.
    public static let required = ["visor-server", "relay-client", "visor-agent-host", "agent-wrapper"]

    /// Throws unless every entry keeps the link rule and every required
    /// name is there.
    public static func check(_ folder: URL, required: [String] = ToolsFolder.required) throws {
        let files = FileManager.default
        let names = try files.contentsOfDirectory(atPath: folder.path)
        for name in names.sorted() {
            if let problem = problem(name, in: folder) { throw ContainerAssetsError.toolRefused(name: name, reason: problem) }
        }
        for name in required where !names.contains(name) { throw ContainerAssetsError.toolMissing(name) }
    }

    /// What's wrong with an entry under the rule; nil when it keeps it.
    public static func problem(_ name: String, in folder: URL) -> String? {
        let path = folder.appendingPathComponent(name).path
        switch kind(path) {
        case .executable: return nil
        case .file: return "it isn't executable"
        case .other: return "it's neither a file nor a link"
        case .missing: return "it isn't there"
        case .link:
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path), !target.isEmpty else {
                return "its link can't be read"
            }
            if target.hasPrefix("/") { return "it's an absolute link (to \(target))" }
            if target.contains("/") { return "its link leaves the folder or goes into another (to \(target))" }
            if target == "." || target == ".." { return "its link is to a folder (\(target))" }
            switch kind(folder.appendingPathComponent(target).path) {
            case .executable: return nil
            case .missing: return "its link is dangling (to \(target), which isn't there)"
            case .link: return "its link is to another link (\(target))"
            case .file: return "its link is to \(target), which isn't executable"
            case .other: return "its link is to \(target), which isn't a file"
            }
        }
    }

    /// The folder for `version` on the Containers volume, made from
    /// `source` (the app's Contents/Resources/Linux) if it isn't there or
    /// isn't the same; checked either way. The copy is made beside it and
    /// moved into place once whole and checked.
    @discardableResult
    public static func stage(from source: URL, layout: ContainerLayout, version: String,
                             required: [String] = ToolsFolder.required) throws -> URL {
        guard let destination = layout.tools(version: version) else { throw ContainerAssetsError.invalidVersion(version) }
        try check(source, required: required)
        let files = FileManager.default
        if files.fileExists(atPath: destination.path), (try? check(destination, required: required)) != nil,
           try same(source, destination) {
            return destination
        }
        try files.createDirectory(at: layout.toolsRoot, withIntermediateDirectories: true)
        let partial = layout.toolsRoot.appendingPathComponent(".\(version).partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: partial) }
        try files.createDirectory(at: partial, withIntermediateDirectories: false)
        for name in try files.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name)
            let to = partial.appendingPathComponent(name)
            if kind(from.path) == .link {
                try files.createSymbolicLink(atPath: to.path, withDestinationPath: try files.destinationOfSymbolicLink(atPath: from.path))
            } else {
                try files.copyItem(at: from, to: to)
            }
        }
        try check(partial, required: required)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: partial, to: destination)
        return destination
    }

    /// Whether two checked folders hold the same entries: the same links,
    /// and files of the same bytes.
    static func same(_ a: URL, _ b: URL) throws -> Bool {
        let files = FileManager.default
        let names = try files.contentsOfDirectory(atPath: a.path).sorted()
        guard names == (try files.contentsOfDirectory(atPath: b.path).sorted()) else { return false }
        for name in names {
            let left = a.appendingPathComponent(name), right = b.appendingPathComponent(name)
            if kind(left.path) == .link {
                guard kind(right.path) == .link,
                      try files.destinationOfSymbolicLink(atPath: left.path) == files.destinationOfSymbolicLink(atPath: right.path) else { return false }
            } else {
                guard kind(right.path) == .executable, try FileDigest.sha256(of: left) == FileDigest.sha256(of: right) else { return false }
            }
        }
        return true
    }

    private enum Kind { case executable, file, link, other, missing }

    /// What's at the path itself (a link not followed).
    private static func kind(_ path: String) -> Kind {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let type = attributes[.type] as? FileAttributeType else {
            return .missing
        }
        switch type {
        case .typeSymbolicLink: return .link
        case .typeRegular:
            let value = attributes[.posixPermissions]
            let mode = (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0
            return mode & 0o111 != 0 ? .executable : .file
        default: return .other
        }
    }
}

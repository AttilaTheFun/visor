import ClaudeTranscript
import Foundation
import VisorProtocol

/// The host's folders, for the client's picker.
enum HostFolders {
    static func resolve(_ path: String) -> String {
        let expanded = (path.isEmpty ? "~" : path) as NSString
        return expanded.expandingTildeInPath
    }

    /// The subfolders of `path` (hidden ones skipped), sorted.
    static func list(_ path: String) -> [String] {
        let resolved = resolve(path)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: resolved)) ?? []
        return entries.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: (resolved as NSString).appendingPathComponent(name), isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Whether the path is still a folder here. A project the user moved or
    /// renamed answers false, which is what the client shows an error for.
    static func exists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: resolve(path), isDirectory: &isDirectory)
        return there && isDirectory.boolValue
    }

    static func make(_ path: String) -> Bool {
        (try? FileManager.default.createDirectory(atPath: resolve(path), withIntermediateDirectories: true)) != nil
    }
}

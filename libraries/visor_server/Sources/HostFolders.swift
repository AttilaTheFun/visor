import ClaudeTranscript
import Foundation
import VisorProtocol

/// The host's folders, for the client's picker.
enum HostFolders {
    /// Where the picker starts, and where a session given no folder (or
    /// "~") works: $VISOR_HOME_FOLDER when it is set, else the user's home.
    static func home(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let set = environment["VISOR_HOME_FOLDER"], !set.isEmpty { return (set as NSString).expandingTildeInPath }
        return ("~" as NSString).expandingTildeInPath
    }

    /// A folder as the host names it: "" and "~" are the home folder;
    /// another path has its "~" expanded.
    static func resolve(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if path.isEmpty || path == "~" { return home(environment) }
        return (path as NSString).expandingTildeInPath
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

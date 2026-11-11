import Foundation
import Synchronization

/// The host's folders: the server's data and sockets, and the client's
/// picker's.
package enum HostFolders {
    /// The data folder, when something other than the platform's is wanted
    /// (tests, a staging server): sessions.json, the hosts' log and the rest.
    package static var dataRoot: URL? {
        get { root.withLock { $0 } }
        set { root.withLock { $0 = newValue } }
    }
    private static let root = Mutex<URL?>(nil)

    /// The data folder: `dataRoot`, else the platform's, made if it isn't
    /// there yet.
    package static var dataFolder: URL {
        let base = dataRoot ?? SystemPlatform.current.host.dataDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// VISOR_RUNTIME_DIR, when it is set: the sockets' folder
    /// (VisorServer+RuntimeDirectory).
    package static func runtimeDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let given = environment["VISOR_RUNTIME_DIR"]?.trimmingCharacters(in: .whitespaces), !given.isEmpty else { return nil }
        return URL(fileURLWithPath: given, isDirectory: true)
    }

    /// Where the picker starts, and where a session given no folder (or
    /// "~") works: $VISOR_HOME_FOLDER when it is set, else the user's home.
    package static func home(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let set = environment["VISOR_HOME_FOLDER"], !set.isEmpty { return (set as NSString).expandingTildeInPath }
        return ("~" as NSString).expandingTildeInPath
    }

    /// A folder as the host names it: "" and "~" are the home folder;
    /// another path has its "~" expanded.
    package static func resolve(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if path.isEmpty || path == "~" { return home(environment) }
        return (path as NSString).expandingTildeInPath
    }

    /// The subfolders of `path` (hidden ones skipped), sorted.
    package static func list(_ path: String) -> [String] {
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
    package static func exists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: resolve(path), isDirectory: &isDirectory)
        return there && isDirectory.boolValue
    }

    package static func make(_ path: String) -> Bool {
        (try? FileManager.default.createDirectory(atPath: resolve(path), withIntermediateDirectories: true)) != nil
    }
}

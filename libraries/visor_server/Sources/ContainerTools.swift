import Foundation
import Synchronization

/// What every container sees of this server, read-only at
/// `ContainerPlacement.toolsFolder`: Visor's MCP script, which the agent
/// there runs with the container's Node. Written into the data directory
/// the first time a container is made in a run (again when it differs from
/// what is there).
enum ContainerTools {
    private static let written = Mutex<URL?>(nil)

    /// The folder, written; nil when it could not be.
    static var folder: URL? {
        written.withLock { folder in
            let directory = ServerPlatform.current.host.dataDirectory.appendingPathComponent("container-tools", isDirectory: true)
            if let folder, folder == directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("visor_mcp.js").path) {
                return folder
            }
            for (name, source, executable) in files {
                let file = directory.appendingPathComponent(name, isDirectory: false)
                let data = Data(source.utf8)
                if (try? Data(contentsOf: file)) != data {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
                }
                if executable { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
            }
            folder = directory
            return directory
        }
    }

    /// Each file: its name, what it holds, and whether it runs.
    private static var files: [(String, String, Bool)] {
        [("visor_mcp.js", VisorMCPScript.source, false)]
    }
}

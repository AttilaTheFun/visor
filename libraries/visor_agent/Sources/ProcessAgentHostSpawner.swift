// The server's own spawner (AgentHostSpawner): the host a child of the
// server's process, run with Foundation's Process (posix_spawn), its output
// and errors appended to the hosts' log, its input /dev/null. Exactly what
// HostedChild did before the spawner was a seam (0.66).

import AgentHostWire
import Foundation

@MainActor
package struct ProcessAgentHostSpawner: AgentHostSpawner {
    package init() {}

    package func spawn(_ request: AgentHostSpawnRequest, program: String) throws -> any SpawnedAgentHost {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = request.hostArguments
        process.currentDirectoryURL = URL(fileURLWithPath: request.folder)
        process.environment = request.processEnvironment
        process.standardInput = FileHandle.nullDevice
        let log = URL(fileURLWithPath: request.log, isDirectory: false)
        if !FileManager.default.fileExists(atPath: log.path) { _ = FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do { try process.run() } catch { throw AgentProcessError.spawnFailed("\(error)") }
        return Spawned(process: process)
    }

    /// The host's process.
    final class Spawned: SpawnedAgentHost {
        let process: Process
        init(process: Process) { self.process = process }
        var isRunning: Bool { process.isRunning }
    }
}

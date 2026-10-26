import Foundation
import Synchronization
@testable import VisorServer

/// Commands in containers, as the server runs them: what it ran, and the
/// agents' command lines (a shell that reads its input and ends).
final class FakeContainerExec: ContainerExecuting {
    let executed = Mutex<[(socket: String, command: [String], input: Data?)]>([])
    let commands = Mutex<[(socket: String, environmentFile: String)]>([])

    func execute(socket: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String) {
        executed.withLock { $0.append((socket, command, input)) }
        return (0, "")
    }

    func command(socket: String, executable: String, arguments: [String], directory: String,
                 environmentFile: String) -> ShellCommand {
        commands.withLock { $0.append((socket, environmentFile)) }
        return ShellCommand("/bin/sh", ["-c", "cat >/dev/null"])
    }
}

import CVisorPOSIX
import Foundation
import VisorServer

/// Agents' hosts on a POSIX system: the host program (visor-agent-host),
/// and the socket file each listens at, reached as a Unix domain socket.
public struct POSIXAgentHosting: AgentHosting {
    public let program: String

    public init(program: String) {
        self.program = program
    }

    public func problem() -> String? {
        guard FileManager.default.isExecutableFile(atPath: program) else { return "there is no agent host at \(program)" }
        guard output(of: program, ["--version"]) != nil else { return "the agent host at \(program) does not run" }
        return nil
    }

    /// The host program beside the running one: how the command-line
    /// server carries it.
    public static func beside(_ executable: String) -> POSIXAgentHosting {
        let folder = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        return POSIXAgentHosting(program: folder.appendingPathComponent("visor-agent-host", isDirectory: false).path)
    }

    @MainActor public func connect(_ path: String) async -> (any ByteStream)? {
        let descriptor = await blocking { visor_connect_unix(path) }
        guard descriptor >= 0 else { return nil }
        return POSIXSocketStream(POSIXSocket(descriptor))
    }
}

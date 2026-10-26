import Foundation
import OSSClient
import VisorServer

/// Commands in the containers sessions lease from the OS Server on this
/// Mac, over each container's own socket (OSSClient's exec): a short one
/// run here to its end, an agent through OS Server's command line (`oss
/// machine exec --socket`) as its host's child, so it outlives a restart of
/// this server and of OS Server alike.
public struct OSSContainerExec: ContainerExecuting {
    /// OS Server's command line: in its app, else where it was linked, else
    /// the first on the path.
    let tool: String

    public init(tool: String? = nil) {
        self.tool = tool ?? Self.locate() ?? "oss"
    }

    static func locate(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let places = ["/Applications/OS Server.app/Contents/Helpers/oss", home + "/Applications/OS Server.app/Contents/Helpers/oss",
                      home + "/.local/bin/oss"] + path.split(separator: ":").map { $0 + "/oss" }
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func execute(socket: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String) {
        let (frames, feed) = AsyncStream<ExecFrame>.makeStream()
        if let input { feed.yield(.stdin(input)) }
        feed.yield(.closeStdin)
        let collected = Collected()
        let status = try await OSSClient.exec(socket: socket, ExecRequest(arguments: command), input: frames) { frame in
            switch frame {
            case .stdout(let data), .stderr(let data): collected.append(data)
            default: break
            }
        }
        feed.finish()
        return (status, collected.text)
    }

    public func command(socket: String, executable: String, arguments: [String], directory: String,
                        environmentFile: String) -> ShellCommand {
        ShellCommand(tool, ["machine", "exec", "--socket=" + socket, "--workdir=" + directory, "--env-file=" + environmentFile,
                            "--", executable] + arguments)
    }
}

// The command-line server: `visor-server` and what follows it. A Visor
// server for a computer without the menu bar app — Linux, Windows — run in
// a terminal, where it says what it is doing as it does it, or in the
// background, where it says it to a log file.

import Foundation
import VisorProtocol
import VisorServer

public struct ServerCommand {
    let system: any CommandLineSystem
    let arguments: [String]

    /// `arguments` without the program's own name.
    public init(system: any CommandLineSystem, arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        self.system = system
        self.arguments = arguments
    }

    static let usage = """
        Usage: visor-server [command] [options]

          run      Runs the server here, saying what it does (the default).
          start    Runs it in the background, logging to a file.
          stop     Stops the one running in the background.
          status   Whether it is running, and where clients reach it.
          password Shows the password (making one if there is none);
                   `password <new>` sets it.
          code     Shows the connection code a client adds this computer with.

        Options for run and start:
          --port <n>   The WebSocket port, the REST side on the next (7433).
          --log <file> Where its lines go (start: visor-server.log in its folder).
        """

    /// Runs the command; what it returns is the process's exit status.
    @MainActor
    public func main() async -> Int32 {
        // A command first, or none (options alone): `run`.
        let named = arguments.first.map { !$0.hasPrefix("-") } ?? false
        let command = named ? arguments[0] : "run"
        let rest = Array(arguments.dropFirst(named ? 1 : 0))
        do {
            switch command {
            case "run": try await run(ServerOptions(rest))
            case "start": try start(ServerOptions(rest))
            case "stop": try await stop()
            case "status": await status()
            case "password": password(rest.first)
            case "code": try await code()
            case "help", "-h", "--help": print(Self.usage)
            default: throw CommandLineError.usage("unknown command \(command)")
            }
            return 0
        } catch CommandLineError.usage(let problem) {
            FileHandle.standardError.write(Data("visor-server: \(problem)\n\n\(Self.usage)\n".utf8))
            return 2
        } catch CommandLineError.failed(let problem) {
            FileHandle.standardError.write(Data("visor-server: \(problem)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("visor-server: \(error)\n".utf8))
            return 1
        }
    }

    /// The file that says which process runs the server, and on which
    /// port: "<pid> <port>".
    var pidFile: URL { system.dataDirectory.appendingPathComponent("visor-server.pid") }

    /// The process running the server, if one is.
    func runningProcess(_ platform: ServerPlatform) -> Int32? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = text.split(whereSeparator: \.isWhitespace).first.flatMap({ Int32($0) }),
              pid != ProcessInfo.processInfo.processIdentifier, platform.processes.isRunning(pid) else { return nil }
        return pid
    }

    /// The platform for a command that does not run the server: what it
    /// says goes nowhere.
    func quietPlatform() -> ServerPlatform {
        let platform = system.platform(log: { _ in }, lifecycle: CommandLineLifecycle(system: system, options: ServerOptions(), cleanUp: {}))
        ServerPlatform.current = platform
        return platform
    }
}

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
          lan      `lan on` lets the LAN reach the server's port; `lan off`
                   (the default) does not.
          vpn      `vpn on` lets a VPN (a tailnet) reach the port; `vpn off`
                   (the default) does not.
          network  `network on|off`: the LAN and a VPN both at once. Off, only
                   this computer reaches the port, with a reverse proxy or
                   a tunnel in front, or SSH.
          ssh      `ssh on` (the default) also serves a socket file only this
                   user can open, for clients that come through the
                   computer's own SSH: no password; `ssh off` leaves them
                   the port, with the password.
          auth     `auth password` (the default) asks clients for the
                   password; `auth none` lets in anyone who reaches the
                   server — the path being the proof (a LAN or VPN of your
                   own, SSH alone, a front that signs users in).
          address  Shows the reverse proxy's or tunnel's address, the one
                   clients are told first; `address <url>` sets it and turns
                   that path on, `address -` turns it off. The server takes
                   it when started again.
          standalone
                   `standalone on`: reached only at the address each client
                   added it at (behind a front of its own), its other
                   addresses shared with no one, and out of the relay
                   between computers; `standalone off` (the default)
                   shares them. Also
                   VISOR_STANDALONE=1.
          front    Shows the paths a front reaches this server at (in a
                   container, behind Visor Runner); `front <url>…` sets them
                   (the computer's loopback, LAN and VPN, e.g.
                   http://192.168.1.20:7440), given to clients in place of
                   this container's own addresses; `front -` clears them.
          keep-messages
                   `keep-messages on` (the default) lets clients keep the
                   sessions' messages on their disk; `keep-messages off`
                   asks them to hold only the pages they show, in memory,
                   and to ask again for those they let go of.
          containers
                   Shows how sessions' containers are made on this computer
                   (docs/container-host.md). `containers host <command…>|-`
                   is the container host that makes them (else
                   visor-container-host on the PATH; with neither, sessions
                   run on this computer only); `containers image <name>|-`
                   is the image (Visor's visor-agent by default, built from
                   tools/containers/visor-agent); `containers callback
                   <ws://host:port>|-` is how they reach this server (this
                   computer's LAN address by default).

        Options for run and start:
          --port <n>   The port, for the socket and the REST side alike (7433).
          --log <file> Where its lines go (start: visor-server.log in its folder).
        Settings for this server, kept as the command of the same name keeps
        them, before it runs (for a server a script or a sandbox starts):
          --password <word>          --auth password|none
          --lan on|off  --vpn on|off  --ssh on|off
          --address <url>|-          --standalone on|off
          --front <url>,…|-
          --keep-messages on|off
          --container-host <command>|-  --container-image <name>|-
        In its environment:
          VISOR_IN_CONTAINER=1
                       This server runs in a container, its agents with it
                       (a co-tenant container): its sessions say so, and
                       clients mark them with a container rather than the
                       system. (Docker's and Podman's containers are found
                       without it.)
          VISOR_DETACH_AGENT_HOST=0|1
                       1 (the default): each session's agent runs under
                       visor-agent-host, beside this program, apart from the
                       server, so a restart leaves it working; an agent that
                       cannot be is not started. 0: agents are the server's
                       own children. (Windows has no host: 0 unless set.)
        """

    /// Runs the command; what it returns is the process's exit status.
    @MainActor
    public func main() async -> Int32 {
        // A command first, or none (options alone): `run`.
        let named = arguments.first.map { !$0.hasPrefix("-") } ?? false
        let command = named ? arguments[0] : "run"
        let rest = Array(arguments.dropFirst(named ? 1 : 0))
        // What a command keeps is in the system's data folder, which the
        // platform says: set first (run and start set their own, with
        // their log). Without it a setting's command stopped the program.
        if command != "run", command != "start" { _ = quietPlatform() }
        do {
            switch command {
            case "run": try await run(ServerOptions(rest))
            case "start": try start(ServerOptions(rest))
            case "stop": try await stop()
            case "status": await status()
            case "password": password(rest.first)
            case "code": try code()
            case "network": try network(rest.first)
            case "lan": try path(.lan, rest.first)
            case "vpn": try path(.vpn, rest.first)
            case "ssh": try ssh(rest.first)
            case "auth": try auth(rest.first)
            case "address": address(rest.first)
            case "standalone": try standalone(rest.first)
            case "front": front(Array(rest))
            case "keep-messages": try keepMessages(rest.first)
            case "containers": try containers(rest)
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

    /// Removes the pid file if it is this process's. One naming another
    /// process is left: the server already running, which a run refused
    /// for it must not leave without its file.
    static func removePidFile(_ file: URL, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let named = (try? String(contentsOf: file, encoding: .utf8))?.split(whereSeparator: \.isWhitespace).first.flatMap { Int32($0) }
        guard named == nil || named == ownPID else { return }
        try? FileManager.default.removeItem(at: file)
    }

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

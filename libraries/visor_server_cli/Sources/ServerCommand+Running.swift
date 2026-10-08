// Running the server: in this process (`run`), in the background
// (`start`), and stopping the one in the background (`stop`).

import Foundation
import VisorProtocol
import VisorServer

extension ServerCommand {
    /// Runs the server in this process until it is asked to stop. In a
    /// terminal it says what it does there, and how a client adds this
    /// computer; with `--log`, it says it to the file.
    @MainActor
    func run(_ options: ServerOptions) async throws {
        let log = CommandLineLog(path: options.log)
        let pidFile = self.pidFile
        let cleanUp: @Sendable () -> Void = { try? FileManager.default.removeItem(at: pidFile) }
        let platform = system.platform(log: { log.write($0) },
                                       lifecycle: CommandLineLifecycle(system: system, options: options, cleanUp: cleanUp))
        ServerPlatform.current = platform
        // The server this one replaces goes first.
        if let after = options.after { await Self.waitForExit(after, platform) }
        if let other = runningProcess(platform) {
            throw CommandLineError.failed("a server is already running (process \(other)); `visor-server stop` stops it")
        }
        let port = options.port ?? Envelope.defaultPort
        try? FileManager.default.createDirectory(at: system.dataDirectory, withIntermediateDirectories: true)
        // Settings given with the run, kept as their commands keep them.
        for (name, value) in options.settings { try apply(name, value) }
        try? Data("\(ProcessInfo.processInfo.processIdentifier) \(port)\n".utf8).write(to: pidFile)

        let server = VisorServer(port: port)
        system.onStop {
            Task { @MainActor in
                log.write("stopping: ending the agents")
                await server.endAll()
                cleanUp()
                exit(0)
            }
        }
        log.write("Visor server on \(platform.host.name), keeping its sessions in \(system.dataDirectory.path)")
        // Setting the password starts the server; so does start(), once.
        if let given = options.password, !given.isEmpty, given != server.password {
            server.password = given
            log.write("the password given with the run is set")
        } else if server.password.isEmpty {
            server.password = Self.newPassword()
            log.write("made a password: `visor-server password` shows it")
        } else {
            server.start()
        }
        if options.log == nil { Task { await announce(server) } }
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// One setting given with a run, kept as its command keeps it.
    @MainActor
    private func apply(_ name: String, _ value: String) throws {
        switch name {
        case "auth": try auth(value)
        case "lan": try path(.lan, value)
        case "vpn": try path(.vpn, value)
        case "ssh": try ssh(value)
        case "address": address(value)
        case "standalone": try standalone(value)
        default: throw CommandLineError.usage("unknown option --\(name)")
        }
    }

    /// The code a client adds this computer with. (Only to a terminal: the
    /// code carries the password.)
    @MainActor
    private func announce(_ server: VisorServer) async {
        guard let code = server.connectionCode else {
            print(server.settings.reachableFromNetwork
                  ? "No address to give yet: this computer has none on a network."
                  : "Only this computer reaches the server: `visor-server network on` opens it to the network, or `visor-server address <url>` names a front of your own.")
            print("`visor-server code` shows the connection code once there is an address.")
            return
        }
        Self.printCode(code)
    }

    static func printCode(_ code: ConnectionCode) {
        print("""

            Reached at \(code.host). In Visor, add this computer with the code:

              \(code.encoded)

            or open \(code.link) on the device.

            """)
    }

    /// Runs the server in the background, logging to a file.
    func start(_ options: ServerOptions) throws {
        let platform = quietPlatform()
        if let pid = runningProcess(platform) {
            print("The server is already running (process \(pid)).")
            return
        }
        try? FileManager.default.createDirectory(at: system.dataDirectory, withIntermediateDirectories: true)
        var background = options
        background.log = options.log ?? system.dataDirectory.appendingPathComponent("visor-server.log").path
        let pid = try system.startDetached(system.executable, ["run"] + background.arguments, log: background.log ?? "")
        print("Started the server in the background (process \(pid)), logging to \(background.log ?? "").")
        print("`visor-server code` shows the connection code; `visor-server stop` stops it.")
    }

    /// Stops the server running in the background: asked over its own REST
    /// side, so it ends its agents first; ended outright if it does not go.
    @MainActor
    func stop() async throws {
        let platform = quietPlatform()
        guard let pid = runningProcess(platform) else {
            print("No server is running.")
            return
        }
        let port = (try? String(contentsOf: pidFile, encoding: .utf8))?.split(whereSeparator: \.isWhitespace).dropFirst().first
            .flatMap { UInt16($0) } ?? Envelope.defaultPort
        let password = platform.secrets.get("password") ?? ""
        let asked = OutgoingRequest(url: "http://127.0.0.1:\(port)/api/quit", method: "POST",
                                    headers: ["Authorization": "Bearer \(password)"], timeout: 5)
        if (try? await platform.fetching.fetch(asked))?.status != 200 { platform.processes.terminate(pid) }
        // It ends its agents before it goes: a few seconds.
        for _ in 0..<150 {
            if !platform.processes.isRunning(pid) {
                print("Stopped.")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        platform.processes.kill(pid)
        print("It had not stopped after 15 seconds: ended it.")
    }

    /// Returns once `pid` has gone, or after half a minute.
    static func waitForExit(_ pid: Int32, _ platform: ServerPlatform) async {
        for _ in 0..<300 where platform.processes.isRunning(pid) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A password for a server that has none: 20 letters and digits.
    static func newPassword() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<20).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

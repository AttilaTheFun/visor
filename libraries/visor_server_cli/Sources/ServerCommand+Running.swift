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
        if server.password.isEmpty {
            // Setting it starts the server.
            server.password = Self.newPassword()
            log.write("made a password: `visor-server password` shows it")
        } else {
            server.start()
        }
        if options.log == nil { Task { await announce(server) } }
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// Once the road in has said where this computer is: the code a client
    /// adds it with. (Only to a terminal: the code carries the password.)
    @MainActor
    private func announce(_ server: VisorServer) async {
        for _ in 0..<60 where server.connectionCode == nil {
            try? await Task.sleep(for: .seconds(1))
        }
        guard let code = server.connectionCode else {
            print(server.serveError.map { "\(server.exposure.title): \($0)" } ?? "\(server.exposure.title) has not said where this computer is.")
            print("`visor-server code` shows the connection code once it has.")
            return
        }
        Self.printCode(code, through: server.exposure.title)
    }

    static func printCode(_ code: ConnectionCode, through road: String) {
        print("""

            Reached at \(code.host) through \(road). In Visor, add this computer with the code:

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
        let asked = OutgoingRequest(url: "http://127.0.0.1:\(port + 1)/api/quit", method: "POST",
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

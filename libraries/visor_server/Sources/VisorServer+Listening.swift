// Listening: one port for the socket and the REST side, on loopback or
// on every interface, plain or over TLS, as the settings say; the same
// on a socket file only this user can open, for clients that come
// through the computer's own SSH (trusted: no password); and the agents'
// model lists kept fresh.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorAgent
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// Listens once there is a password (or nothing is asked); without
    /// one the menu says so and Settings is where to go. Visor.app's own
    /// server (`appKey` set) listens on its socket file from the start, so
    /// the app can set one.
    public func start() {
        if appKey != nil, socketListener == nil {
            _ = serving()
            listenForSSH()
        }
        guard listener == nil, !password.isEmpty || settings.asksNothing else { return }
        // An agent that has gone leaves a pipe that cannot be written to:
        // that is an error to the write, not a signal that ends the app.
        ServerPlatform.current.processes.ignoreBrokenPipes()
        // Where the agents' tools are, for those not in the usual places.
        let tools = harnesses.all.map(\.tool) + ["node"]
        Task {
            await ToolPath.locate(tools)
            broadcastCatalogs()
        }
        let http = serving()
        let options = ListeningOptions(port: port, everywhere: settings.reachableFromNetwork, tls: tlsIdentity)
        do {
            try listen(options)
        } catch {
            listening = false
            lastError = "\(error)"
            Self.log("could not listen on \(port): \(error); trying again for \(Self.listenRetries / 2) seconds")
            retryListening(options, for: http)
        }
        listenForSSH()
        keepModelsFresh()
        keepSessionTokensFresh()
        resumePending()
        // A super compact the last server went away under carries on.
        resumeSuperCompaction()
    }

    /// The socket file: `~/.visor/server.sock`, short enough for a socket
    /// path anywhere, in a folder of this user's alone; where the binary
    /// places it (`placedSocketPath`: Visor.app's on the Visor volume,
    /// `/Volumes/Visor/run/server.sock`); in VISOR_RUNTIME_DIR when that is
    /// set (a home that can't hold a socket) — or where a test or a staging
    /// server puts its own, away from the installed server's.
    public static var socketPath: String {
        if let socketPathOverride { return socketPathOverride }
        if let runtime = runtimeDirectory() { return runtime.appendingPathComponent("server.sock", isDirectory: false).path }
        if let placedSocketPath { return placedSocketPath }
        return legacySocketPath
    }
    public static var socketPathOverride: String?
    /// Where the binary keeps the socket file instead of `~/.visor`: set
    /// before the server starts, and in the clients of the same process.
    public static var placedSocketPath: String?

    /// `~/.visor/server.sock`: the socket file before the Visor volume, and
    /// what an SSH client of 0.64 still reaches (`nc -U
    /// ~/.visor/server.sock`). With the socket file placed elsewhere, it's a
    /// link to it for one release (0.65, and 0.66 for the app group's
    /// container), then goes (docs/DEVELOPMENT.md).
    public static var legacySocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".visor/server.sock", isDirectory: false).path
    }

    /// Where else the socket file was, linked to the one placed (with
    /// `legacySocketPath`) for a release: in 0.66, with the socket file in
    /// the app group's container, the Visor volume's `run/server.sock`,
    /// which a 0.65 SSH client asks for first.
    public static var legacySocketLinks: [String] = []

    /// The REST side's server, made the first time a listener needs it
    /// after a start (the socket file's may be first).
    private func serving() -> HTTPServer {
        if let http { return http }
        let http = HTTPServer { [weak self] request, respond in
            guard let self else { return respond(HTTPResponse(500, "{\"error\":\"gone\"}")) }
            self.route(request, respond: respond)
        }
        self.http = http
        return http
    }

    /// Listens on the socket file, when SSH clients are let in without a
    /// password, or Visor.app is this server's client (`appKey`). A system
    /// without socket files, or a folder that cannot be made, is logged and
    /// leaves the port as the only path.
    private func listenForSSH() {
        guard settings.sshEnabled || appKey != nil, socketListener == nil else { return }
        let path = Self.socketPath
        let folder = (path as NSString).deletingLastPathComponent
        // Another server answers there (the installed one, with this one a
        // headless or a test server beside it): its SSH clients stay its.
        if ServerPlatform.current.listening.answers(unixPath: path) {
            Self.log("not listening for SSH clients: another server answers at \(path); this one keeps to its port")
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            socketListener = try ServerPlatform.current.listening.listen(ListeningOptions(port: port, unixPath: path)) { [weak self] stream in
                self?.accept(stream, trusted: true)
            }
            Self.log("listening for SSH clients at \(path)")
            linkLegacySockets(to: path)
        } catch {
            Self.log("not listening for SSH clients: \(error)")
        }
    }

    /// `~/.visor/server.sock` (and `legacySocketLinks`) a link to the socket
    /// file placed elsewhere (for a release: an SSH client of 0.64 asks for
    /// that path, one of 0.65 for the volume's), unless a server still
    /// answers there; the folder made this user's alone.
    private func linkLegacySockets(to path: String) {
        guard Self.socketPathOverride == nil else { return }
        for legacy in [Self.legacySocketPath] + Self.legacySocketLinks where legacy != path { linkLegacySocket(legacy, to: path) }
    }

    private func linkLegacySocket(_ legacy: String, to path: String) {
        let files = FileManager.default
        if (try? files.destinationOfSymbolicLink(atPath: legacy)) == path { return }
        if ServerPlatform.current.listening.answers(unixPath: legacy) {
            Self.log("\(legacy) is another server's socket: it isn't linked to \(path)")
            return
        }
        do {
            try files.createDirectory(atPath: (legacy as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            try? files.removeItem(atPath: legacy)
            try files.createSymbolicLink(atPath: legacy, withDestinationPath: path)
        } catch {
            Self.log("\(legacy) couldn't be linked to \(path): \(error)")
        }
    }

    /// Asks the agents for their models now and every few hours (a new
    /// model, a changed plan), and tells the clients when a list changed.
    /// Again a few minutes after launch, and after an answer that dropped
    /// models: one given while the account was still being checked can be
    /// the base models alone.
    func keepModelsFresh() {
        modelsRefresh?.cancel()
        modelsRefresh = Task {
            var soon = true
            while !Task.isCancelled {
                // In the Sessions container while it's on (VisorServer+ContainerClaude).
                async let claude = refreshClaudeModels()
                async let codex = CodexHarness.refreshModels()
                // OpenRouter's list, from its CLI, when it is a day old.
                async let openrouter = OpenRouterHarness.refreshIfStale()
                let answers = await (claude, codex, openrouter)
                if answers.0 == .changed || answers.1 == .changed || answers.2 { broadcastCatalogs() }
                let again: Duration = soon || answers.0 == .doubted ? .seconds(5 * 60) : .seconds(6 * 60 * 60)
                soon = false
                try? await Task.sleep(for: again)
            }
        }
    }

    /// How many times, half a second apart, a port that couldn't be
    /// listened on is tried again: the server this one replaces may still
    /// be letting go of it (a restart, 2 Nov 2026).
    static let listenRetries = 20

    /// Listens on the port, as the options say.
    private func listen(_ options: ListeningOptions) throws {
        listener = try ServerPlatform.current.listening.listen(options) { [weak self] stream in self?.accept(stream) }
        listening = true
        lastError = nil
        Self.log("listening on \(options.everywhere ? "every interface" : "127.0.0.1"):\(port)\(options.tls == nil ? "" : " with TLS")")
    }

    /// The port tried again, half a second apart, while this start's
    /// listening stands (not stopped, nor started again since).
    private func retryListening(_ options: ListeningOptions, for http: HTTPServer) {
        Task {
            for _ in 0..<Self.listenRetries {
                try? await Task.sleep(for: .milliseconds(500))
                guard self.http === http, listener == nil else { return }
                do {
                    try listen(options)
                    return
                } catch {
                    lastError = "\(error)"
                }
            }
            Self.log("could not listen on \(port): \(lastError ?? "")")
        }
    }

    public func stop() {
        stopListening()
        sessionTokenRefresh?.cancel()
        sessionTokenRefresh = nil
        // Whoever was waiting on a transcript gets what there is, now.
        for record in sessions { answerTranscriptWaiters(for: record) }
        for connection in connections.values { connection.close() }
        connections.removeAll()
        clientCount = 0
    }

    func stopListening() {
        listener?.stop()
        listener = nil
        socketListener?.stop()
        socketListener = nil
        listening = false
        http = nil
    }

    /// A connection: its first bytes say whether it is the live channel or
    /// a request of the REST side. A trusted one (the socket file) is let
    /// in without the password.
    func accept(_ stream: any ByteStream, trusted: Bool = false) {
        // A path that is off: the connection is closed unanswered.
        if !trusted, !admits(localAddress: stream.localAddress) {
            if let address = stream.localAddress, refusedPaths.insert(address).inserted {
                Self.log("a connection on \(address) was refused: that network path is off")
            }
            stream.close()
            return
        }
        FrontDoor(stream: stream, socket: { [weak self] stream, received in
            self?.acceptClient(stream, received: received, trusted: trusted)
        }, http: { [weak self] stream, received in
            self?.http?.serve(stream, received: received, trusted: trusted)
        }).start()
    }

    private func acceptClient(_ stream: any ByteStream, received: Data, trusted: Bool) {
        let client = ClientConnection(stream: stream, received: received)
        if let end = HTTPServer.headerEnd(received) {
            client.headers = HTTPServer.headers(String(decoding: received[..<end], as: UTF8.self))
        }
        // The socket file's: as this user, while SSH clients are, or for
        // Visor.app itself.
        client.trusted = trusts(socketFile: trusted, headers: client.headers)
        let key = ObjectIdentifier(client)
        connections[key] = client
        clientCount = connections.count
        client.onMessage = { [weak self, weak client] envelope in
            guard let self, let client else { return }
            self.handle(envelope, from: client)
        }
        client.onClose = { [weak self] in
            guard let self else { return }
            let gone = self.connections.removeValue(forKey: key)
            self.clientCount = self.connections.count
            if let gone { self.logLeaving(gone) }
            for session in self.sessions { session.subscribers.remove(key) }
            if let gone { self.withdrawApprovals(askedBy: gone) }
        }
        client.start()
    }
}

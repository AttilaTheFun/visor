// Listening: one port for the socket and the REST side, on loopback or
// on every interface, plain or over TLS, as the settings say; the same
// on a socket file only this user can open, for clients that come
// through the computer's own SSH (trusted: no password); and the agents'
// model lists kept fresh.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension VisorServer {
    /// Listens once there is a password; without one the menu says so
    /// and Settings is where to go.
    public func start() {
        guard listener == nil, !password.isEmpty else { return }
        // An agent that has gone leaves a pipe that cannot be written to:
        // that is an error to the write, not a signal that ends the app.
        ServerPlatform.current.processes.ignoreBrokenPipes()
        // Where the agents' tools are, for those not in the usual places.
        let tools = harnesses.all.map(\.tool) + ["node"]
        Task {
            await ToolPath.locate(tools)
            broadcastCatalogs()
        }
        let http = HTTPServer { [weak self] request, respond in
            guard let self else { return respond(HTTPResponse(500, "{\"error\":\"gone\"}")) }
            self.route(request, respond: respond)
        }
        self.http = http
        let options = ListeningOptions(port: port, everywhere: settings.reachableFromNetwork, tls: tlsIdentity)
        do {
            listener = try ServerPlatform.current.listening.listen(options) { [weak self] stream in self?.accept(stream) }
            listening = true
            lastError = nil
            Self.log("listening on \(options.everywhere ? "every interface" : "127.0.0.1"):\(port)\(options.tls == nil ? "" : " with TLS")")
        } catch {
            listening = false
            lastError = "\(error)"
            Self.log("could not listen on \(port): \(error)")
        }
        listenForSSH()
        keepModelsFresh()
        resumePending()
    }

    /// The socket file: `~/.visor/server.sock`, short enough for a socket
    /// path anywhere, in a folder of this user's alone — or where a test
    /// or a staging server puts its own, away from the installed server's.
    public static var socketPath: String {
        socketPathOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".visor/server.sock").path
    }
    public static var socketPathOverride: String?

    /// Listens on the socket file, when SSH clients are let in without a
    /// password. A system without socket files, or a folder that cannot
    /// be made, is logged and leaves the port as the only road.
    private func listenForSSH() {
        guard settings.sshEnabled, socketListener == nil else { return }
        let path = Self.socketPath
        let folder = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            socketListener = try ServerPlatform.current.listening.listen(ListeningOptions(port: port, unixPath: path)) { [weak self] stream in
                self?.accept(stream, trusted: true)
            }
            Self.log("listening for SSH clients at \(path)")
        } catch {
            Self.log("not listening for SSH clients: \(error)")
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
                async let claude = ClaudeHarness.refreshModels()
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

    public func stop() {
        stopListening()
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
        FrontDoor(stream: stream, socket: { [weak self] stream, received in
            self?.acceptClient(stream, received: received, trusted: trusted)
        }, http: { [weak self] stream, received in
            self?.http?.serve(stream, received: received, trusted: trusted)
        }).start()
    }

    private func acceptClient(_ stream: any ByteStream, received: Data, trusted: Bool) {
        let client = ClientConnection(stream: stream, received: received)
        client.trusted = trusted
        let key = ObjectIdentifier(client)
        connections[key] = client
        clientCount = connections.count
        Self.log("a client connected (\(clientCount) now)")
        client.onMessage = { [weak self, weak client] envelope in
            guard let self, let client else { return }
            self.handle(envelope, from: client)
        }
        client.onClose = { [weak self] in
            guard let self else { return }
            self.connections.removeValue(forKey: key)
            self.clientCount = self.connections.count
            Self.log("a client left (\(self.clientCount) now)")
            for session in self.sessions { session.subscribers.remove(key) }
        }
        client.start()
    }
}

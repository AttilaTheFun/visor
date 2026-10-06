// Listening: one port for the socket and the REST side, on loopback or
// on every interface, plain or over TLS, as the settings say; and the
// agents' model lists kept fresh.

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
        keepModelsFresh()
        resumePending()
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
        listening = false
        http = nil
    }

    /// A connection: its first bytes say whether it is the live channel or
    /// a request of the REST side.
    func accept(_ stream: any ByteStream) {
        FrontDoor(stream: stream, socket: { [weak self] stream, received in
            self?.acceptClient(stream, received: received)
        }, http: { [weak self] stream, received in
            self?.http?.serve(stream, received: received)
        }).start()
    }

    private func acceptClient(_ stream: any ByteStream, received: Data) {
        let client = ClientConnection(stream: stream, received: received)
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

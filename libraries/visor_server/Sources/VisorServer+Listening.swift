// Listening: the socket and the REST side on loopback, the front put on
// 443 by the exposure, and the agents' model lists kept fresh.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension VisorServer {
    /// Listens once there is a password; without one the menu says so
    /// and Settings is where to go. The listeners take loopback only:
    /// the front is the one way in from the network.
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
        let http = HTTPServer(port: apiPort) { [weak self] request, respond in
            guard let self else { return respond(HTTPResponse(500, "{\"error\":\"gone\"}")) }
            self.route(request, respond: respond)
        }
        do { try http.start(); self.http = http } catch { lastError = "API: \(error)" }
        do {
            listener = try ServerPlatform.current.listening.listen(port: port) { [weak self] stream in self?.accept(stream) }
            listening = true
            lastError = nil
            Self.log("listening on 127.0.0.1:\(port) (WebSocket) and :\(apiPort) (REST)")
        } catch {
            listening = false
            lastError = "\(error)"
            Self.log("could not listen on \(port): \(error)")
        }
        front()
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

    /// The front on 443, put in place whenever it is not: there is no
    /// switch for it. What goes wrong is shown in the menu.
    /// At login the menu bar app and Tailscale start together, so the
    /// first try often finds Tailscale not yet up: no owner and no front.
    /// It tries again — every few seconds at first, then every minute —
    /// until both are known.
    public func front() {
        // One attempt at a time; one asked for meanwhile runs after it, as
        // it may know something the running one did not.
        guard fronting == nil else { frontAgain = true; return }
        let exposure = self.exposure
        let port = self.port
        guard exposure.installed else {
            if serveError == nil { Self.log("\(exposure.title) is not installed: clients reach this computer through it") }
            serveError = "\(exposure.title) is not installed"
            return
        }
        fronting = Task {
            var message: String?
            let identity = await exposure.identity()
            let address = await exposure.address()
            if identity == nil {
                message = "waiting for \(exposure.title)"
            } else if await !exposure.fronts(port: port) {
                let output = await exposure.front(port: port).lowercased()
                if output.contains("error") || output.contains("not enabled") || output.contains("not allowed") {
                    message = output.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? output
                }
            }
            fronting = nil
            if frontAgain {
                frontAgain = false
                front()
                return
            }
            if let identity { hostLogin = identity }
            if let address, address != self.address {
                self.address = address
                Self.log("reached at \(address) through \(exposure.title)")
            }
            if message != serveError, let message { Self.log("\(exposure.title): \(message)") }
            serveError = message
            guard message != nil else { frontAttempts = 0; return }
            frontAttempts += 1
            let wait = frontAttempts < 24 ? 5 : 60
            Task {
                try? await Task.sleep(for: .seconds(wait))
                front()
            }
        }
    }

    /// Returns once the attempt under way, if there is one, has learned
    /// what it could (tests).
    func fronted() async { await fronting?.value }

    public func stop() {
        listener?.stop()
        listener = nil
        listening = false
        http?.stop()
        http = nil
        // Whoever was waiting on a transcript gets what there is, now.
        for record in sessions { answerTranscriptWaiters(for: record) }
        for connection in connections.values { connection.close() }
        connections.removeAll()
        clientCount = 0
    }

    func accept(_ stream: any ByteStream) {
        let client = ClientConnection(stream: stream)
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

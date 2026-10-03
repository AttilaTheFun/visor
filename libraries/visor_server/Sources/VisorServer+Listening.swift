// Listening: the socket and the REST side on loopback, the front put on
// 443 by the exposure, and the agents' model lists kept fresh.

import AppKit
import ClaudeTranscript
import MessageCache
import Foundation
import Network
import VisorProtocol

extension VisorServer {
    /// The host's Tailscale (100.64.0.0/10) and other IPv4 addresses.
    public static func addresses() -> [(name: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let name = String(cString: ifa.ifa_name)
                if address == "127.0.0.1" { continue }
                result.append((name, address))
            }
        }
        // Tailscale first: the CGNAT range on a utun interface.
        return result.sorted { a, b in a.1.hasPrefix("100.") && !b.1.hasPrefix("100.") }
    }

    /// Listens once there is a password; without one the menu says so
    /// and Settings is where to go. The listeners take loopback only:
    /// the front is the one way in from the network.
    public func start() {
        guard listener == nil, !password.isEmpty else { return }
        // An agent that has gone leaves a pipe that cannot be written to:
        // that is an error to the write, not a signal that ends the app.
        signal(SIGPIPE, SIG_IGN)
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
            let params = NWParameters(tls: nil)
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let listener = try NWListener(using: params)
            // The listener's queue is the main one: what it says is taken
            // as it is said, in order.
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.listening = true; self?.lastError = nil
                    case .failed(let error): self?.listening = false; self?.lastError = "\(error)"
                    case .cancelled: self?.listening = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = "\(error)"
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
        guard exposure.installed else { serveError = "\(exposure.title) is not installed"; return }
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
            if let address { self.address = address }
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
        listener?.cancel()
        listener = nil
        http?.stop()
        http = nil
        // Whoever was waiting on a transcript gets what there is, now.
        for record in sessions { answerTranscriptWaiters(for: record) }
        for connection in connections.values { connection.close() }
        connections.removeAll()
        clientCount = 0
    }

    func accept(_ nw: NWConnection) {
        let client = ClientConnection(connection: nw)
        let key = ObjectIdentifier(client)
        connections[key] = client
        clientCount = connections.count
        client.onMessage = { [weak self, weak client] envelope in
            guard let self, let client else { return }
            self.handle(envelope, from: client)
        }
        client.onClose = { [weak self] in
            guard let self else { return }
            self.connections.removeValue(forKey: key)
            self.clientCount = self.connections.count
            for session in self.sessions { session.subscribers.remove(key) }
        }
        client.start()
    }
}

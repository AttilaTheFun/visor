// Following a server without its live channel. The one-shot side has
// everything the channel carries but a terminal's bytes: the list of
// sessions (`GET /sessions?since=`), a session's ephemeral state
// (`GET /sessions/<id>/state?since=`) and the rows before one
// (`GET /sessions/<id>/earlier?before=`), each held by the server until
// there is something new. Asked for in a loop, they arrive as the same
// events the channel would bring, and nothing above hears the difference
// beyond `.transport(live: false)`. The socket is tried again every so
// often; when it opens, its own `welcome` takes over and the polling stops.

import VisorProtocol
import VisorServices

extension HTTPAgentServer {
    /// How long the socket is left alone before it is tried again, and
    /// how many answers in a row the list may fail before the server is
    /// taken as gone.
    static let socketRetryInterval: Int32 = 90_000
    static let pollFailuresAllowed = 3
    /// A breath between one answer and the next ask, so a stream of
    /// deltas does not become a request per word.
    static let pollBreath: Int32 = 400

    /// One run of polling: its loops, and the sessions followed.
    @MainActor
    final class Polling {
        let onEvent: @MainActor (AgentServerEvent) -> Void
        var list: Task<Void, Never>?
        var states: [String: Task<Void, Never>] = [:]
        var retry: Task<Void, Never>?
        init(onEvent: @escaping @MainActor (AgentServerEvent) -> Void) { self.onEvent = onEvent }

        func cancel() {
            list?.cancel()
            retry?.cancel()
            for task in states.values { task.cancel() }
            states = [:]
        }
    }

    /// Follows the server by polling from here: the list first (its
    /// answer is the `welcome`), then each change to it; the socket is
    /// tried again now and then.
    func poll(_ address: ServerAddress, onEvent: @escaping @MainActor (AgentServerEvent) -> Void, after reason: String? = nil) {
        stopPolling()
        let polling = Polling(onEvent: onEvent)
        self.polling = polling
        ConnectionLog.shared.note(record.name.isEmpty ? record.address : record.name,
                                  "following by polling" + (reason.map { " (\($0))" } ?? " (no socket on this host)"))
        polling.list = Task { [weak self, weak polling] in
            var revision: Int?
            var failures = 0
            var welcomed = false
            while !Task.isCancelled {
                guard let self, let polling, self.polling === polling else { return }
                do {
                    let path = revision.map { "/sessions?since=\($0)" } ?? "/sessions"
                    let answer = try await self.call("GET", path)
                    guard !Task.isCancelled, self.polling === polling else { return }
                    failures = 0
                    guard answer.type == "welcome" else { throw AgentServerError.message("not a welcome") }
                    if !welcomed {
                        welcomed = true
                        onEvent(.welcome(name: answer.host ?? "", sessions: answer.sessions ?? [], catalogs: answer.catalogs ?? []))
                        onEvent(.transport(live: false))
                    } else if answer.revision != revision {
                        onEvent(.sessions(answer.sessions ?? []))
                        onEvent(.catalogs(answer.catalogs ?? []))
                    }
                    revision = answer.revision
                    await self.delay(milliseconds: Self.pollBreath)
                } catch {
                    guard !Task.isCancelled, self.polling === polling else { return }
                    // A refusal is the server asking for a password; the
                    // road being down for a while is the channel dropping.
                    if VisorHost.http?.status(of: error) == 401 {
                        self.stopPolling()
                        return onEvent(.refused("Wrong password"))
                    }
                    failures += 1
                    if failures >= Self.pollFailuresAllowed {
                        self.stopPolling()
                        return onEvent(.closed("No answer while polling"))
                    }
                    await self.delay(milliseconds: 2_000)
                }
            }
        }
        polling.retry = Task { [weak self, weak polling] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.delay(milliseconds: Self.socketRetryInterval)
                guard !Task.isCancelled, let polling, self.polling === polling, VisorHost.socket != nil else { continue }
                // The channel again, from the top: it stops the polling
                // when it is answered, and the polling goes on otherwise.
                self.openChannel(onEvent: onEvent)
                return
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// Follows one session's state while polling: each answer is the
    /// `ephemeral` envelope the channel would have sent on subscribing.
    func pollState(of session: String) {
        guard let polling, polling.states[session] == nil else { return }
        polling.states[session] = Task { [weak self, weak polling] in
            var revision: Int?
            while !Task.isCancelled {
                guard let self, let polling, self.polling === polling else { return }
                do {
                    let path = "/sessions/\(Self.escape(session))/state" + (revision.map { "?since=\($0)" } ?? "")
                    let answer = try await self.call("GET", path)
                    guard !Task.isCancelled, self.polling === polling else { return }
                    guard answer.type == "ephemeral" else { continue }
                    if answer.revision != revision { polling.onEvent(.session(answer)) }
                    revision = answer.revision
                    await self.delay(milliseconds: Self.pollBreath)
                } catch {
                    guard !Task.isCancelled else { return }
                    // Gone for good: nothing more to follow.
                    if VisorHost.http?.status(of: error) == 404 { return }
                    await self.delay(milliseconds: 2_000)
                }
            }
        }
    }

    /// The rows before one, asked for outright: they arrive as the
    /// `earlier` envelope the channel would have sent.
    func pollEarlier(of session: String, before: String) {
        guard let polling else { return }
        Task { [weak self, weak polling] in
            guard let self, let answer = try? await self.call("GET", "/sessions/\(Self.escape(session))/earlier?before=\(Self.escape(before))"),
                  let polling, self.polling === polling, answer.type == "earlier" else { return }
            polling.onEvent(.session(answer))
        }
    }
}

// Other computers' Visor Servers, linked so the agents on each can reach
// the sessions on the others. A link is the other computer's connection
// code, pasted into Settings on one of them: this server keeps it (in the
// keychain, as it holds a password) and hands the other its own code, so
// the link goes both ways. Nothing is discovered: a computer is linked
// only by its code.
//
// A session on a linked computer is named `<computer>/<id>`, the computer
// by its name in lower case (`logans-macbook-pro/1tzn…`). What an agent
// asks about one goes to that computer's `POST /api/agent`, which answers
// as it would its own agents, with the caller named as from here.

import Foundation
import VisorProtocol

extension VisorServer {
    /// A computer's name as it appears in a session id: lower case, words
    /// joined by dashes.
    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        return words.joined(separator: "-")
    }

    /// This computer's part of a session id, as the linked computers know it.
    var slug: String { Self.slug(hostName) }

    /// The links as kept, one connection code per line.
    static func keptLinks() -> [ConnectionCode] {
        (secrets.get("links") ?? "").split(separator: "\n").compactMap { ConnectionCode(parsing: String($0)) }
    }

    private func keepLinks() {
        Self.secrets.set("links", links.map(\.encoded).joined(separator: "\n"))
    }

    /// Links the computer a connection code names, and hands it this
    /// computer's code so it links back. Nil when done; otherwise what
    /// went wrong. Linking again replaces the code (a new password).
    public func link(_ text: String) async -> String? {
        guard let code = ConnectionCode(parsing: text) else { return "That is not a connection code." }
        if code.host == address { return "That is this computer's own code." }
        adopt(code)
        guard let mine = connectionCode else { return nil }
        var e = Envelope(type: "link")
        e.text = mine.encoded
        do {
            _ = try await call(code, path: "link", e)
            return nil
        } catch {
            return "Linked here, but \(code.name) did not take the link back: \(error.localizedDescription)"
        }
    }

    public func unlink(host: String) {
        links.removeAll { $0.host == host }
        keepLinks()
    }

    /// A code kept, replacing any for the same computer.
    func adopt(_ code: ConnectionCode) {
        if let index = links.firstIndex(where: { $0.host == code.host }) {
            links[index] = code
        } else {
            links.append(code)
        }
        keepLinks()
    }

    /// What an agent asked, answered — by this server for its own
    /// sessions, or by the linked computer a session id names.
    func answerAgent(_ envelope: Envelope, reply: @escaping @MainActor (Envelope) -> Void) {
        guard envelope.token == agentToken, let caller = session(envelope.client) else {
            reply(agentReply(envelope))
            return
        }
        let name = caller.info.title.isEmpty ? caller.info.agent.title : caller.info.title
        var forward = envelope
        forward.type = "agent"
        forward.token = nil
        forward.client = "\(slug)/\(caller.info.id)"
        forward.title = name
        forward.host = hostName
        switch envelope.mode {
        case "sessions" where !links.isEmpty:
            let here = agentReply(envelope)
            let links = self.links
            Task { @MainActor in
                var sections = [(here.text ?? "").isEmpty || here.text == "No other sessions." ? "On this computer: none." : "On this computer:\n" + (here.text ?? "")]
                for link in links {
                    let prefix = Self.slug(link.name)
                    do {
                        let answer = try await self.call(link, path: "agent", forward)
                        if let error = answer.error {
                            sections.append("On \(link.name): \(error)")
                        } else {
                            let lines = (answer.text ?? "").split(separator: "\n").map { "\(prefix)/\($0)" }
                            sections.append(lines.isEmpty ? "On \(link.name): none." : "On \(link.name):\n" + lines.joined(separator: "\n"))
                        }
                    } catch {
                        sections.append("On \(link.name): not reachable (\(error.localizedDescription)).")
                    }
                }
                var result = here
                result.text = sections.joined(separator: "\n\n")
                reply(result)
            }
        case "send", "read":
            guard let target = envelope.session, let slash = target.lastIndex(of: "/") else {
                reply(agentReply(envelope))
                return
            }
            let computer = String(target[..<slash])
            var result = Envelope(type: "agent_result")
            result.id = envelope.id
            guard let link = links.first(where: { Self.slug($0.name) == computer }) else {
                result.error = "No linked computer \(computer); list_sessions names the sessions on each."
                reply(result)
                return
            }
            forward.session = String(target[target.index(after: slash)...])
            Task { @MainActor in
                do {
                    let answer = try await self.call(link, path: "agent", forward)
                    result.text = answer.text
                    result.error = answer.error
                } catch {
                    result.error = "\(link.name) is not reachable: \(error.localizedDescription)"
                }
                reply(result)
            }
        default:
            reply(agentReply(envelope))
        }
    }

    /// One request to a linked computer's REST side, with its password.
    /// The code's host is its network name (HTTPS on 443), or a whole
    /// base address (`http://127.0.0.1:7434`), which tests use.
    func call(_ link: ConnectionCode, path: String, _ envelope: Envelope) async throws -> Envelope {
        let base = link.host.contains("://") ? link.host : "https://\(link.host)"
        let request = OutgoingRequest(url: "\(base)/api/\(path)", method: "POST",
                                      headers: ["Authorization": "Bearer \(link.password)", "Content-Type": "application/json"],
                                      body: Data(envelope.encoded().utf8))
        let answer = try await ServerPlatform.current.fetching.fetch(request)
        guard let reply = Envelope.decode(String(decoding: answer.body, as: UTF8.self), defaultType: "error") else {
            throw NSError(domain: "Visor", code: answer.status, userInfo: [NSLocalizedDescriptionKey: "it answered \(answer.status)"])
        }
        if answer.status >= 400 {
            throw NSError(domain: "Visor", code: answer.status,
                          userInfo: [NSLocalizedDescriptionKey: reply.error ?? reply.message ?? "it answered \(answer.status)"])
        }
        return reply
    }
}

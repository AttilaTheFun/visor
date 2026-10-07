// The other computers on the network: each a peer this server keeps —
// its id, name, addresses and password — so the agents here reach the
// sessions there, clients that reach this server learn of the others,
// and this server relays for peers a client cannot reach itself. A peer
// comes from a connection code pasted into Settings, from a client that
// holds two servers and introduces them, or from another peer passing on
// what it knows: whatever one computer learns, it tells the rest, until
// all know all. Nothing is discovered on the wire; a computer joins by
// its code, once, anywhere.
//
// A session on a peer is named `<computer>/<id>`, the computer by its
// name in lower case (`logans-macbook-pro/1tzn…`). What an agent asks
// about one goes to that computer's `POST /api/agent`, which answers as
// it would its own agents, with the caller named as from here. A peer is
// reached at one of its own addresses, or through another peer that
// reaches it (`/peer/<id>/…` there), whichever answered last time first.

import Foundation
import VisorProtocol

extension VisorServer {
    /// This server's id on the network.
    public var id: String { settings.serverID }

    /// A computer's name as it appears in a session id: lower case, words
    /// joined by dashes.
    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        return words.joined(separator: "-")
    }

    /// This computer's part of a session id, as the peers know it.
    var slug: String { Self.slug(hostName) }

    /// The peers as kept, one per line — or, from before peers, the
    /// links, each a connection code.
    static func keptPeers() -> [Peer] {
        let kept = (secrets.get("peers") ?? "").split(separator: "\n").compactMap { parseJSON(String($0)).flatMap(Peer.init(json:)) }
        if !kept.isEmpty { return kept }
        return (secrets.get("links") ?? "").split(separator: "\n").compactMap { ConnectionCode(parsing: String($0))?.peer }
    }

    private func keepPeers() {
        Self.secrets.set("peers", peers.map { $0.json.encoded() }.joined(separator: "\n"))
    }

    /// This server's own addresses, as clients read them: its network
    /// paths that are on — the proxy's URL, `http(s)://` on each address
    /// of the LAN and the VPN, `ssh://user@` on each address. What its
    /// peers and clients are told.
    public var ownAddresses: [String] {
        var out: [String] = []
        let set = settings.publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.proxyEnabled, !set.isEmpty { out.append(set) }
        return out + httpPaths + sshPaths
    }

    /// This computer as its peers should know it, its SSH key with it.
    public var ownPeer: Peer { Peer(id: id, name: hostName, addresses: ownAddresses, password: password, sshKey: ownSSHKey ?? "") }

    /// Takes in a connection code pasted here: the computer becomes a
    /// peer, is handed this computer's code so it knows this one back,
    /// and both tell their peers. Nil when done; otherwise what went wrong.
    public func link(_ text: String) async -> String? {
        guard let code = ConnectionCode(parsing: text) else { return "That is not a connection code." }
        if (!code.id.isEmpty && code.id == id) || code.host == reachableAddress { return "That is this computer's own code." }
        _ = adopt(code.peer)
        guard let mine = connectionCode else { return nil }
        var e = Envelope(type: "link")
        e.text = mine.encoded
        do {
            guard let peer = peers.first(where: { $0.isSame(as: code.peer) }) else { return nil }
            _ = try await call(peer, path: "link", e)
            tellPeers(except: peer.id)
            return nil
        } catch {
            return "Linked here, but \(code.name) did not take the link back: \(error.localizedDescription)"
        }
    }

    /// Forgets a peer, by its id or an address of its.
    public func forget(peer key: String) {
        peers.removeAll { $0.id == key || $0.addresses.contains(key) }
        workingPaths.removeValue(forKey: key)
        keepPeers()
    }

    /// Takes in what is said of a computer: a new peer, or more of one
    /// known (its id, an address, a new password). This computer itself
    /// is never a peer. Whether anything changed.
    @discardableResult
    func adopt(_ peer: Peer) -> Bool {
        guard !peer.addresses.isEmpty, peer.id != id || id.isEmpty else { return false }
        if peer.id.isEmpty, !Set(peer.addresses).isDisjoint(with: ownAddresses) { return false }
        let keyBefore = peers.first { $0.isSame(as: peer) }?.sshKey ?? ""
        if let index = peers.firstIndex(where: { $0.isSame(as: peer) }) {
            guard peers[index].merge(peer) else { return false }
        } else {
            peers.append(peer)
        }
        keepPeers()
        // A peer's server comes in through this computer's SSH as a
        // device does: whoever told of it was let in already.
        if !peer.sshKey.isEmpty, peer.sshKey != keyBefore, let problem = authorizeSSHKey(peer.sshKey) {
            Self.log("\(peer.name)'s SSH key was not taken: \(problem)")
        }
        return true
    }

    /// Takes in several (from a client, or a peer passing on what it
    /// knows), and passes on to the rest whatever was news — so what one
    /// computer learns, all learn, and nothing is passed on twice.
    func adopt(_ told: [Peer], from teller: String?) {
        var changed = false
        for peer in told where adopt(peer) { changed = true }
        if changed { tellPeers(except: teller) }
    }

    /// Tells every peer (but `except`) of all this computer knows: itself
    /// and its peers.
    func tellPeers(except: String?) {
        var e = Envelope(type: "peers")
        e.peers = [ownPeer] + peers
        for peer in peers where peer.id != except && !peer.id.isEmpty {
            Task { @MainActor in _ = try? await self.call(peer, path: "peers", e) }
        }
    }

    /// What an agent asked, answered — by this server for its own
    /// sessions, or by the peer a session id names.
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
        case "sessions" where !peers.isEmpty:
            let here = agentReply(envelope)
            let peers = self.peers
            Task { @MainActor in
                var sections = [(here.text ?? "").isEmpty || here.text == "No other sessions." ? "On this computer: none." : "On this computer:\n" + (here.text ?? "")]
                for peer in peers {
                    let prefix = Self.slug(peer.name)
                    do {
                        let answer = try await self.call(peer, path: "agent", forward)
                        if let error = answer.error {
                            sections.append("On \(peer.name): \(error)")
                        } else {
                            let lines = (answer.text ?? "").split(separator: "\n").map { "\(prefix)/\($0)" }
                            sections.append(lines.isEmpty ? "On \(peer.name): none." : "On \(peer.name):\n" + lines.joined(separator: "\n"))
                        }
                    } catch {
                        sections.append("On \(peer.name): not reachable (\(error.localizedDescription)).")
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
            guard let peer = peers.first(where: { Self.slug($0.name) == computer }) else {
                result.error = "No computer \(computer) on the network; list_sessions names the sessions on each."
                reply(result)
                return
            }
            forward.session = String(target[target.index(after: slash)...])
            Task { @MainActor in
                do {
                    let answer = try await self.call(peer, path: "agent", forward)
                    result.text = answer.text
                    result.error = answer.error
                } catch {
                    result.error = "\(peer.name) is not reachable: \(error.localizedDescription)"
                }
                reply(result)
            }
        default:
            reply(agentReply(envelope))
        }
    }

    /// The paths to a peer's REST side, the one that answered last time
    /// first: its own HTTP addresses, its SSH ones where this system has
    /// SSH (`base(for:)` opens the tunnel), then through each other peer
    /// that was reached (`/peer/<id>` there).
    func paths(to peer: Peer) -> [String] {
        var out = peer.addresses.compactMap { address -> String? in
            guard SSHAddress(address) == nil, let parsed = ServerAddress(address) else { return nil }
            return parsed.root
        }
        if ServerPlatform.current.ssh != nil {
            out += peer.addresses.filter { SSHAddress($0) != nil }
        }
        if !peer.id.isEmpty {
            for other in peers where other.id != peer.id && !other.id.isEmpty {
                if let known = workingPaths[other.id], !known.contains("/peer/") { out.append(known + "/peer/" + peer.id) }
            }
        }
        // The one that answered last time first, while it is still a path.
        if let known = workingPaths[peer.id.isEmpty ? (peer.addresses.first ?? "") : peer.id], let index = out.firstIndex(of: known) {
            out.remove(at: index)
            out.insert(known, at: 0)
        }
        return out
    }

    /// One request to a peer's REST side, with its password, down the
    /// first path that answers; a peer from before ids is asked who it
    /// is on the way.
    func call(_ peer: Peer, path: String, _ envelope: Envelope) async throws -> Envelope {
        var lastError: Error = NSError(domain: "Visor", code: 0, userInfo: [NSLocalizedDescriptionKey: "no address to reach it at"])
        for way in paths(to: peer) {
            do {
                let base = try await base(for: way)
                let answer = try await Self.post(base + "/api/" + path, password: peer.password, envelope, relay: [id])
                workingPaths[peer.id.isEmpty ? (peer.addresses.first ?? "") : peer.id] = way
                if peer.id.isEmpty { identify(peer, at: base) }
                return answer
            } catch {
                dropTunnel(for: way)
                lastError = error
            }
        }
        throw lastError
    }

    /// A peer from before ids: asked for its hello, which says who it is
    /// (its id and addresses; its name stays as the code gave it).
    private func identify(_ peer: Peer, at base: String) {
        Task { @MainActor in
            let request = OutgoingRequest(url: base + "/api/hello", headers: ["Authorization": "Bearer \(peer.password)"])
            guard let answer = try? await ServerPlatform.current.fetching.fetch(request), answer.status == 200,
                  let hello = Envelope.decode(String(decoding: answer.body, as: UTF8.self)), let learned = hello.id, !learned.isEmpty else { return }
            self.adopt(Peer(id: learned, name: peer.name, addresses: peer.addresses + (hello.addresses ?? []), password: peer.password))
        }
    }

    /// One POST with a password, as a peer or a relay makes it; the
    /// `X-Visor-Relay` header names the servers it has passed through.
    static func post(_ url: String, password: String, _ envelope: Envelope, relay: [String]) async throws -> Envelope {
        let request = OutgoingRequest(url: url, method: "POST",
                                      headers: ["Authorization": "Bearer \(password)", "Content-Type": "application/json", "X-Visor-Relay": relay.joined(separator: ",")],
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

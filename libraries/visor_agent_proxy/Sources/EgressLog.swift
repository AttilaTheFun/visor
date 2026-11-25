// The egress log (MultiPass's host log, Visor's docs/server-proxy.md, "The
// log"): every connection an agent makes through the relay, a line of JSON
// each, so egress can be limited later from what agents actually reach
// (Logan, 2026-11-14: "egress stays open, but log each connection agents
// make"). Each line has the host and port, the container's lease (the
// relay's TLV 0xE1), the agent the request claims to be, when it names one
// (`agentClaimed`: its own `X-Agent-ID`, or a forward's client header, so
// self-reported), the time (ISO 8601), the route (GitHub's
// hosts, Anthropic's API, a dial-in, a forward, or plain egress) and how it
// went. Hosts, not
// contents: no request line past its target, no header, no token, nothing a
// tunnel carries is ever written. GitHub's requests, opened by the
// interceptor (phase 2), are a line each besides: the method, the path's
// class and the gate's decision, never a body, a header or a token; and so
// are Anthropic's (its interceptor's: allow or refuse). The one before is kept as `<name>.1.<ext>`
// once the file passes its limit. The file is opened afresh for each line,
// never through a symbolic link, and kept 0600.

import CAgentProxyPOSIX
import Foundation

/// Where the relay took each agent, a line each.
public final class EgressLog: Sendable {
    /// How a connection went.
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        /// A CONNECT tunnel, or a dial-in, its bytes passed through untouched.
        case tunnelled
        /// Opened by GitHub's interceptor, a credential added (phase 2's).
        case opened
        /// Plain HTTP, or a forward's request, sent on.
        case forwarded
        /// Refused: an address of this computer's, a name of the agent
        /// proxy's that isn't a dial-in, or a forward with no key.
        case refused
        /// It couldn't be reached.
        case unreachable
        /// The stream ended, or wasn't HTTP, before anything went on.
        case dropped
    }

    /// Which way a connection went.
    public enum Route: String, Codable, Sendable, CaseIterable {
        /// One of GitHub's hosts (GitHubHosts), intercepted or not.
        case github
        /// api.anthropic.com (AnthropicInterceptor), intercepted or not; a
        /// request in it a line each, with its method, its path's class and
        /// whether it went on (`allow` or `refuse`).
        case anthropic
        /// A server's loopback port, by its `<name>.agent.internal` (DialIn).
        case dialIn = "dial-in"
        /// Shireworks' API, with agent-proxy's key for it (Forward); a
        /// request on it a line each, with its method, its path's class and
        /// whether it was let through (`allow` or `refuse`).
        case forward
        /// Anywhere else off this computer.
        case egress
    }

    /// One connection.
    public struct Entry: Codable, Equatable, Sendable {
        public var time: Date
        public var host: String
        public var port: Int
        /// The container's lease id, as the relay named it.
        public var lease: String
        /// The agent the request claimed to be (a lower-case UUID), as it said
        /// so itself; nil when it named none.
        public var agentClaimed: String?
        public var route: Route
        public var outcome: Outcome
        /// A request in GitHub's interception (route `github`, phase 2), or on
        /// the forward (route `forward`, phase 3), each a line of its own: its
        /// method, its path's class (no query, numbers `{n}`:
        /// GitHubGate.pathClass), and the decision (`allow`, `anonymous`,
        /// `check` or `refuse`). Nil for a connection.
        public var method: String?
        public var pathClass: String?
        public var decision: String?

        public init(time: Date = Date(), host: String, port: Int, lease: String, agentClaimed: String? = nil, route: Route, outcome: Outcome,
                    method: String? = nil, pathClass: String? = nil, decision: String? = nil) {
            self.time = time
            self.host = host
            self.port = port
            self.lease = lease
            self.agentClaimed = agentClaimed
            self.route = route
            self.outcome = outcome
            self.method = method
            self.pathClass = pathClass
            self.decision = decision
        }

        /// Who made it, for the summaries: `container:<lease>`.
        public var caller: String { "container:\(lease)" }
    }

    /// One caller's host, all its entries together.
    public struct Summary: Equatable, Sendable {
        public var caller: String
        public var host: String
        public var port: Int
        public var count: Int
        public var last: Date
        public var outcomes: Set<Outcome>
    }

    public let file: URL
    private let limit: Int
    private let writing = Locked(())

    /// Logging to `file`, kept to about `limit` bytes (and one file before).
    public init(file: URL, limit: Int = 8 << 20) {
        self.file = file
        self.limit = limit
    }

    /// The file before this one: `Shireworks-egress.1.log` beside `Shireworks-egress.log`.
    public var previous: URL {
        file.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(file.pathExtension)
    }

    public func record(_ entry: Entry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        writing.withLock { _ in
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size + line.count > limit {
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: file, to: previous)
            }
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = agent_proxy_open_log(file.path)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            HTTPRequest.send(descriptor, line)
        }
    }

    /// Every entry kept, oldest first; a line that isn't one is passed over.
    public func entries() -> [Entry] {
        [previous, file].flatMap { url -> [Entry] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(Entry.self, from: Data($0)) }
        }
    }

    /// `entries` by caller and host, the callers and their hosts in order.
    public static func summaries(_ entries: [Entry]) -> [Summary] {
        var found: [String: Summary] = [:]
        for entry in entries {
            let key = "\(entry.caller) \(entry.host):\(entry.port)"
            var summary = found[key] ?? Summary(caller: entry.caller, host: entry.host, port: entry.port, count: 0, last: entry.time, outcomes: [])
            summary.count += 1
            summary.last = max(summary.last, entry.time)
            summary.outcomes.insert(entry.outcome)
            found[key] = summary
        }
        return found.values.sorted { ($0.caller, $0.host, $0.port) < ($1.caller, $1.host, $1.port) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// ServerSettings' `agentProxy` (Logan, 19 Nov 2026: Shireworks' agent-proxy
// is Visor's now; docs/agent-proxy.md): what Visor's agent-proxy serves and
// how. It is libraries/visor_agent_proxy, run on a Mac as the app's own
// executable with `--agent-proxy` (a launchd job the server keeps while this
// is set), and on Linux inside visor-server. None: no agent-proxy at all,
// the default, so nothing changes on a computer until it is configured.
//
// - `mcp`: the native sessions' MCP pass-through on loopback (7439 unless
//   said), each upstream at `/mcp/<name>`, a call let through with the
//   sessions' token (`X-Visor-Proxy`), its secret headers added from the
//   server's secrets. What a session's `mcpEndpoints` point at.
// - `relayPort`: the relay listener on loopback, the containers' way out:
//   their egress (by `egressAllow`), the GitHub gate (with the auth token),
//   DNS (split by `dns`), the dial-ins and the egress log. None: no relay
//   listener (nothing of Visor's relays containers to it yet).
// - `gh`: gh_mcp, answered in-process at the pass-through's `/mcp/gh`
//   (libraries/visor_gh_mcp; Logan, 2026-11-21: "fold gh_mcp into Visor's
//   agent-proxy at /mcp/gh"), the session known by its CLIENT_ID behind the
//   sessions' token. None: none. An upstream named `gh` in `mcp` wins: the
//   cut-over from gh_mcp's LaunchAgent (7470) is this set and that removed.
//
// Its secrets are the server's (the keychain on a Mac, the secrets file
// elsewhere), each `agent-proxy/<name>` (`secretKey`), never in these
// settings: `github-token` (the GitHub credential the gate attaches; none:
// no GitHub through the proxy), `github-app/key`, `github-app/id` and
// `github-app/installation` (the GitHub App whose installation tokens the
// gate attaches instead, when its key and id are set: from 0.71.1),
// `mcp/token` (the sessions' token) and
// `mcp/<upstream>/<header>` (an upstream's secret header), imported with
// `agent-proxy secret-set <name>` from standard input; and the relay's token
// and the GitHub authority, which agent-proxy makes itself.
//
// Decoded field by field: a field left out is its default, so a file from
// before one reads as it did.

import Foundation

public struct AgentProxySettings: Codable, Equatable, Sendable {
    /// The native sessions' MCP pass-through.
    public struct MCP: Codable, Equatable, Sendable {
        /// Shireworks' and MultiPass's before it, so sessions' `mcpEndpoints`
        /// don't change.
        public static let defaultPort = 7439
        /// Its port, on loopback alone.
        public var port: Int
        /// The MCP servers calls are passed on to, each at `/mcp/<name>`.
        public var upstreams: [Upstream]

        public init(port: Int = MCP.defaultPort, upstreams: [Upstream] = []) {
            self.port = port
            self.upstreams = upstreams
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
            upstreams = try c.decodeIfPresent([Upstream].self, forKey: .upstreams) ?? []
        }
    }

    /// An MCP server the pass-through reaches: its name (`/mcp/<name>`),
    /// its plain HTTP(S) address, its plain headers, the names of those whose
    /// values are secrets (`agent-proxy/mcp/<name>/<header>`), and the tools
    /// no session is given.
    public struct Upstream: Codable, Equatable, Sendable {
        public var name: String
        public var url: String
        public var headers: [String: String]
        public var secretHeaders: [String]
        public var withheldTools: [String]

        public init(name: String, url: String, headers: [String: String] = [:], secretHeaders: [String] = [], withheldTools: [String] = []) {
            self.name = name
            self.url = url
            self.headers = headers
            self.secretHeaders = secretHeaders
            self.withheldTools = withheldTools
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            url = try c.decode(String.self, forKey: .url)
            headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            secretHeaders = try c.decodeIfPresent([String].self, forKey: .secretHeaders) ?? []
            withheldTools = try c.decodeIfPresent([String].self, forKey: .withheldTools) ?? []
        }
    }

    /// gh_mcp in agent-proxy: what its tools may touch (`repositories`,
    /// `AttilaTheFun/*` unless said), whom a session acts as on GitHub
    /// (`agent`, logan-shire-agent unless said, or the session's own in
    /// `sessionAgents`, by session id: logan-shire-claude, -codex or
    /// -agent, or claude, codex or agent as agent-token names them), the
    /// command that gives an agent's installation token (`agentToken`,
    /// `~/.local/bin/agent-token`, run as `<it> token <agent> --owner
    /// <owner>`), where each call is logged (`auditLog`; none: the
    /// server's logs folder's `Visor-gh.log`, beside the egress log), and
    /// the tools no session is given (`withheldTools`, gh_mcp's names, as an
    /// upstream's).
    ///
    /// A session is known by its CLIENT_ID, which is trusted only as far as
    /// the sessions' token is: whoever holds that token may send any
    /// CLIENT_ID, and so act as any app `sessionAgents` names. Give no
    /// session there an app with more on GitHub than `agent`'s. (Binding a
    /// call to its session's own JWT, so a CLIENT_ID can't be another's, is
    /// for later.)
    public struct GH: Codable, Equatable, Sendable {
        public static let defaultRepositories = ["AttilaTheFun/*"]
        public static let defaultAgent = "logan-shire-agent"
        public static let defaultAgentToken = "~/.local/bin/agent-token"

        public var repositories: [String]?
        public var agentToken: String?
        public var agent: String?
        public var sessionAgents: [String: String]
        public var auditLog: String?
        /// Its tools kept from the sessions (refused, and left out of `tools/list`), as an upstream's `withheldTools`.
        public var withheldTools: [String]

        public init(repositories: [String]? = nil, agentToken: String? = nil, agent: String? = nil, sessionAgents: [String: String] = [:],
                    auditLog: String? = nil, withheldTools: [String] = []) {
            self.repositories = repositories
            self.agentToken = agentToken
            self.agent = agent
            self.sessionAgents = sessionAgents
            self.auditLog = auditLog
            self.withheldTools = withheldTools
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repositories = try c.decodeIfPresent([String].self, forKey: .repositories)
            agentToken = try c.decodeIfPresent(String.self, forKey: .agentToken)
            agent = try c.decodeIfPresent(String.self, forKey: .agent)
            sessionAgents = try c.decodeIfPresent([String: String].self, forKey: .sessionAgents) ?? [:]
            auditLog = try c.decodeIfPresent(String.self, forKey: .auditLog)
            withheldTools = try c.decodeIfPresent([String].self, forKey: .withheldTools) ?? []
        }
    }

    /// A server's port containers reach as `<name>.agent.internal:<port>`,
    /// joined to `hostPort` on this computer's loopback (the same port
    /// unless said).
    public struct DialIn: Codable, Equatable, Sendable {
        public var name: String
        public var port: Int
        public var hostPort: Int

        public init(name: String, port: Int, hostPort: Int? = nil) {
            self.name = name
            self.port = port
            self.hostPort = hostPort ?? port
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            port = try c.decode(Int.self, forKey: .port)
            hostPort = try c.decodeIfPresent(Int.self, forKey: .hostPort) ?? port
        }
    }

    /// The resolver's split: the tailnet's names (`tailnetSuffixes`, ts.net
    /// unless said) to its resolvers alone (`tailnet`; none unless said, so
    /// they're answered no such name), the rest to this computer's own, then
    /// `fallbacks` (1.1.1.1, then 8.8.8.8, unless said).
    public struct DNS: Codable, Equatable, Sendable {
        public var tailnetSuffixes: [String]?
        public var tailnet: [String]?
        public var fallbacks: [String]?

        public init(tailnetSuffixes: [String]? = nil, tailnet: [String]? = nil, fallbacks: [String]? = nil) {
            self.tailnetSuffixes = tailnetSuffixes
            self.tailnet = tailnet
            self.fallbacks = fallbacks
        }
    }

    /// The native sessions' MCP pass-through; none: none.
    public var mcp: MCP?
    /// The relay listener's loopback port; none: no relay listener.
    public var relayPort: Int?
    /// What containers' egress may reach beyond the internet: CIDRs or
    /// addresses of the private ranges, or destinations as a CONNECT names
    /// them (`nas.local:443`, `host:port@CIDR`). None: the LAN and the
    /// tailnet are refused. This computer's own addresses always are.
    public var egressAllow: [String]
    /// The resolver's split; none: the defaults.
    public var dns: DNS?
    /// The servers on this computer containers may dial in to; none unless
    /// listed.
    public var dialIns: [DialIn]
    /// The relay listener's streams at once, in all and of one container
    /// (512 and 128 unless said).
    public var maxConnections: Int?
    public var maxConnectionsPerLease: Int?
    /// Where each container connection is logged, a JSON line each; none:
    /// `agent-proxy/egress.log` in the server's data folder (on a Mac,
    /// Visor-egress.log in Visor's logs: the Visor volume's Logs/, else ~/Library/Logs).
    public var egressLog: String?
    /// Where the GitHub authority's certificate is written for containers
    /// to trust; none: `agent-proxy/ca.pem` in the data folder.
    public var caCertificate: String?
    /// A gate.json in place of the gate's standard rules; none:
    /// `agent-proxy/gate.json` in the data folder where there is one.
    public var gateRules: String?
    /// gh_mcp, in-process at the pass-through's `/mcp/gh`; none: none.
    public var gh: GH?

    public init(mcp: MCP? = nil, relayPort: Int? = nil, egressAllow: [String] = [], dns: DNS? = nil, dialIns: [DialIn] = [],
                maxConnections: Int? = nil, maxConnectionsPerLease: Int? = nil, egressLog: String? = nil, caCertificate: String? = nil,
                gateRules: String? = nil, gh: GH? = nil) {
        self.mcp = mcp
        self.relayPort = relayPort
        self.egressAllow = egressAllow
        self.dns = dns
        self.dialIns = dialIns
        self.maxConnections = maxConnections
        self.maxConnectionsPerLease = maxConnectionsPerLease
        self.egressLog = egressLog
        self.caCertificate = caCertificate
        self.gateRules = gateRules
        self.gh = gh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcp = try c.decodeIfPresent(MCP.self, forKey: .mcp)
        relayPort = try c.decodeIfPresent(Int.self, forKey: .relayPort)
        egressAllow = try c.decodeIfPresent([String].self, forKey: .egressAllow) ?? []
        dns = try c.decodeIfPresent(DNS.self, forKey: .dns)
        dialIns = try c.decodeIfPresent([DialIn].self, forKey: .dialIns) ?? []
        maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections)
        maxConnectionsPerLease = try c.decodeIfPresent(Int.self, forKey: .maxConnectionsPerLease)
        egressLog = try c.decodeIfPresent(String.self, forKey: .egressLog)
        caCertificate = try c.decodeIfPresent(String.self, forKey: .caCertificate)
        gateRules = try c.decodeIfPresent(String.self, forKey: .gateRules)
        gh = try c.decodeIfPresent(GH.self, forKey: .gh)
    }

    // MARK: Its secrets

    /// What every one of agent-proxy's secrets is kept under, before its
    /// name: no other of the server's secrets is agent-proxy's to read.
    public static let secretPrefix = "agent-proxy/"
    /// The GitHub credential the gate attaches for containers' sessions.
    public static let githubTokenName = "github-token"
    /// The GitHub App's private key, a PEM (PKCS #1 or #8): with its id, the
    /// gate attaches the App's installation tokens in place of `github-token`.
    public static let githubAppKeyName = "github-app/key"
    /// The GitHub App's id.
    public static let githubAppIDName = "github-app/id"
    /// The App's installation's id, optional: without it, the installation is
    /// the one of the gate's owner.
    public static let githubAppInstallationName = "github-app/installation"
    /// The native sessions' token, which a call shows in `X-Visor-Proxy`.
    public static let mcpTokenName = "mcp/token"
    /// The relay's token, which each relayed stream's header carries:
    /// agent-proxy's to make.
    public static let relayTokenName = "relay-token"

    /// Where `name` is kept with the server's secrets.
    public static func secretKey(_ name: String) -> String { secretPrefix + name }

    /// An upstream's secret header's name (`mcp/<upstream>/<header>`), the
    /// header lower-cased: HTTP's names have no case.
    public static func mcpSecretName(upstream: String, header: String) -> String { "mcp/\(upstream)/\(header.lowercased())" }

    /// `name` as the import takes it: given with or without
    /// `agent-proxy/`, and an upstream's header lower-cased. Nil when it is
    /// none of the secrets one sets: `github-token`, `github-app/key`,
    /// `github-app/id`, `github-app/installation`, `mcp/token`, or
    /// `mcp/<upstream>/<header>` (letters, digits, `-`, `_` and `.`, at most
    /// 64 each).
    public static func importableName(_ given: String) -> String? {
        let name = given.hasPrefix(secretPrefix) ? String(given.dropFirst(secretPrefix.count)) : given
        if [githubTokenName, githubAppKeyName, githubAppIDName, githubAppInstallationName, mcpTokenName].contains(name) { return name }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "mcp" else { return nil }
        let valid = parts.dropFirst().allSatisfy { part in
            !part.isEmpty && part.count <= 64 && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
        return valid ? mcpSecretName(upstream: String(parts[1]), header: String(parts[2])) : nil
    }
}

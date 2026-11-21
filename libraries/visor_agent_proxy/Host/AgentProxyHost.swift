// Visor's agent-proxy, run (Logan, 19 Nov 2026: Shireworks' agent-proxy is
// Visor's; docs/agent-proxy.md): from ServerSettings' `agentProxy` and the
// server's secrets, the native sessions' MCP pass-through and the relay
// listener (the containers' egress, GitHub gate, DNS and dial-ins). Run two
// ways, the same code:
//
// - on a Mac, as Visor itself, `Visor.app/Contents/MacOS/Visor
//   --agent-proxy`, a launchd job the server keeps (AgentProxyJob): the
//   app's own executable, so it carries the app's signature and reads the
//   server's keychain items as the app does (a bare tool in Contents/Helpers
//   would be another program to the keychain). `run` is that process;
// - on Linux, inside visor-server (`start`, at the server's start).
//
// Moved from Shireworks' v0.15.1 (Sources/AgentProxyHost), without what was
// Shireworks' own: the `shireworks.agent.internal` forward and
// `/mcp/shireworks` (with its agent key), logan-shire-agent's App key (the
// gate attaches the auth token Settings keep instead), and the relay token
// handed over on standard input (it's the server's secret alone).
//
// Its secrets (ProxySecretStore: the server's `agent-proxy/` items), each
// read again at most once a minute (KeptSecret), so one imported with
// `agent-proxy secret-set` is taken without a restart:
// - `relay-token`, which every relayed stream's PROXY v2 header must carry
//   (TLV 0xE2): made here the first time, kept;
// - `github-token`, the GitHub credential the gate attaches; none: what
//   needs one is refused;
// - `ca.pem` and `ca-key.pem`, the GitHub authority: made here the first
//   time, its certificate written for the containers to trust;
// - `mcp/token`, the sessions' token (`X-Visor-Proxy`); none: every call
//   refused;
// - `mcp/<upstream>/<header>`, an upstream's secret header.
//
// From 0.66, `agentProxy.gh` adds gh_mcp, answered in this process at the
// pass-through's `/mcp/gh` (GitHubMCP) where `mcp` has no upstream named
// gh; with `gh` and no `mcp`, the pass-through listens on its own port
// (7439) for it alone.

import Crypto
import Foundation
import VisorAgentProxy
import VisorServer
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum AgentProxyHost {
    /// Where agent-proxy keeps what isn't secret: `agent-proxy/` in the
    /// server's data folder (its authority's certificate, a gate.json if one
    /// is put there, the settings it last started with), and its egress log.
    public struct Places: Sendable {
        /// The server's data folder: its settings.json is there.
        public var dataDirectory: URL
        /// The egress log's path where the settings name none.
        public var egressLog: String
        /// gh_mcp's audit log's where `agentProxy.gh` names none: in the
        /// server's logs folder, beside the egress log given (a Mac's:
        /// `Visor-gh.log` in Visor's logs, ~/Library/Logs or, on 0.65's
        /// layout, /Volumes/Visor/Logs), else `agent-proxy/gh.log` in the
        /// data folder.
        public var ghAuditLog: String

        public init(dataDirectory: URL, egressLog: String? = nil, ghAuditLog: String? = nil) {
            self.dataDirectory = dataDirectory
            self.egressLog = egressLog ?? dataDirectory.appendingPathComponent("agent-proxy/egress.log").path
            self.ghAuditLog = ghAuditLog
                ?? egressLog.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("Visor-gh.log").path }
                ?? dataDirectory.appendingPathComponent("agent-proxy/gh.log").path
        }

        /// `<data folder>/agent-proxy`.
        public var folder: URL { dataDirectory.appendingPathComponent("agent-proxy", isDirectory: true) }
        /// The server's settings, ServerSettings'.
        public var settingsFile: URL { dataDirectory.appendingPathComponent("settings.json") }
        /// What it last started with, for a settings.json that can't be read.
        public var keptFile: URL { folder.appendingPathComponent("last-good.json") }
        public var caCertificate: String { folder.appendingPathComponent("ca.pem").path }
        public var gateRules: String { folder.appendingPathComponent("gate.json").path }
    }

    /// What runs: the relay listener and the MCP pass-through, each where
    /// it's configured and could listen.
    public final class Running: Sendable {
        public let relay: RelayListener?
        public let nativeMCP: NativeMCPProxy?
        let interceptor: GitHubInterceptor?
        /// Whether each listener configured is listening.
        public let complete: Bool

        init(relay: RelayListener?, nativeMCP: NativeMCPProxy?, interceptor: GitHubInterceptor?, complete: Bool) {
            self.relay = relay
            self.nativeMCP = nativeMCP
            self.interceptor = interceptor
            self.complete = complete
        }

        public func stop() {
            relay?.stop()
            nativeMCP?.stop()
            interceptor?.stop()
        }
    }

    /// agent-proxy started from `settings`: each listener configured, and
    /// what couldn't listen said. Nil when nothing is configured.
    /// `settingsFile` is read again at each dial-in's CONNECT, so a dial-in
    /// added needs no restart.
    public static func start(_ settings: AgentProxySettings, places: Places, secrets: any SecretStore, version: String,
                             log: @escaping @Sendable (String) -> Void) -> Running? {
        guard settings.relayPort != nil || settings.mcp != nil || settings.gh != nil else {
            log("agentProxy has neither `mcp`, `gh` nor `relayPort`: nothing to serve")
            return nil
        }
        try? FileManager.default.createDirectory(at: places.folder, withIntermediateDirectories: true)
        let store = ProxySecretStore(secrets: secrets)
        var relay: RelayListener?
        var interceptor: GitHubInterceptor?
        var failed = false
        if let port = settings.relayPort {
            (relay, interceptor) = startRelay(settings, port: port, places: places, secrets: secrets, store: store, log: log)
            failed = relay == nil
        }
        var nativeMCP: NativeMCPProxy?
        if settings.mcp != nil || settings.gh != nil {
            nativeMCP = startMCP(settings.mcp ?? AgentProxySettings.MCP(), gh: settings.gh, places: places, secrets: secrets, log: log)
            failed = failed || nativeMCP == nil
        }
        let serving = [relay == nil ? nil : "the relay listener", nativeMCP == nil ? nil : "the MCP pass-through"].compactMap { $0 }
        log((version.isEmpty ? "" : "\(version), ") + "pid \(getpid()): agent-proxy serves " + (serving.isEmpty ? "nothing" : serving.joined(separator: " and "))
            + (failed ? ", not all it was asked for" : ""))
        return Running(relay: relay, nativeMCP: nativeMCP, interceptor: interceptor, complete: !failed)
    }

    /// The relay listener, its egress proxy, GitHub's interception and DNS.
    private static func startRelay(_ settings: AgentProxySettings, port: Int, places: Places, secrets: any SecretStore,
                                   store: ProxySecretStore, log: @escaping @Sendable (String) -> Void)
        -> (RelayListener?, GitHubInterceptor?) {
        let maxConnections = settings.maxConnections ?? RelayListener.defaultMaxConnections
        let maxConnectionsPerLease = settings.maxConnectionsPerLease ?? RelayListener.defaultMaxConnectionsPerLease
        if let problem = RelayListener.capsProblem(maxConnections: maxConnections, maxConnectionsPerLease: maxConnectionsPerLease) {
            log("agentProxy: \(problem): no relay listener")
            return (nil, nil)
        }
        // Made first, then read: a KeptSecret keeps what it read for a
        // minute, so one asked before the token was made would refuse every
        // relayed stream for that minute (a container booted within it had
        // no egress).
        if case .absent = secrets.lookup(AgentProxySettings.secretKey(AgentProxySettings.relayTokenName)) {
            secrets.set(AgentProxySettings.secretKey(AgentProxySettings.relayTokenName), SecretToken.mint())
            log("the relay's token made (agent-proxy/relay-token)")
        }
        let relayToken = KeptSecret(AgentProxySettings.relayTokenName, in: secrets)
        let egressPath = settings.egressLog ?? places.egressLog
        try? FileManager.default.createDirectory(atPath: (egressPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let egress = EgressLog(file: URL(fileURLWithPath: egressPath))
        let policy = EgressPolicy(allow: settings.egressAllow)
        for entry in policy.rejected { log("egressAllow's \(entry) passed over: not a CIDR, an address, a host:port or a host:port@CIDR") }
        if !policy.ranges.isEmpty || !policy.destinations.isEmpty {
            log("egressAllow lists this computer's networks: on macOS that needs Visor's Local Network permission (\(EgressProxy.localNetworkHint))")
        }
        let githubToken = KeptSecret(AgentProxySettings.githubTokenName, in: secrets)
        let gateRules = settings.gateRules ?? (FileManager.default.fileExists(atPath: places.gateRules) ? places.gateRules : nil)
        let interceptor = GitHubInterceptor.make(secrets: store, caCertificate: settings.caCertificate ?? places.caCertificate,
                                                 gateRules: gateRules, token: { githubToken.value }, egress: egress, log: log)
        let proxy = EgressProxy(policy: policy, interceptor: interceptor, egress: egress, log: log)
        var dns = DNSSettings(hosts: [])
        if let split = settings.dns {
            if let suffixes = split.tailnetSuffixes { dns.tailnetSuffixes = suffixes }
            if let tailnet = split.tailnet { dns.tailnet = tailnet }
            if let fallbacks = split.fallbacks { dns.fallbacks = fallbacks }
        }
        let resolver = DNSForwarder(routes: { [dns] in dns.routes() }, exchange: NIODNSExchange(), log: log)
        let initial = dialIns(settings, log: log)
        let settingsFile = places.settingsFile
        guard let relay = RelayListener(port: port, relayToken: { relayToken.value }, proxy: proxy, dns: resolver,
                                        dialIns: { (try? configured(at: settingsFile)).flatMap { $0 }.map { Self.dialIns($0, log: nil) } ?? initial },
                                        maxConnections: maxConnections, maxConnectionsPerLease: maxConnectionsPerLease, log: log) else {
            log("loopback port \(port) can't be had for the relay listener (another listener on it?)")
            interceptor?.stop()
            return (nil, nil)
        }
        relay.start()
        let listed = policy.ranges + policy.destinations.sorted().map { destination in
            policy.pins[destination].map { "\(destination)@\($0.joined(separator: "+"))" } ?? destination
        }
        log("the relay listener is on loopback port \(port), answering DNS, logging egress to \(egressPath)"
            + (listed.isEmpty ? ", egress to the internet alone" : ", egress to the internet and \(listed.joined(separator: ", "))")
            + initial.map { ", \($0.host):\($0.port) to loopback port \($0.hostPort)" }.joined()
            + (githubToken.isSet ? "" : "; no auth token for GitHub (agent-proxy secret-set github-token): what needs one is refused"))
        return (relay, interceptor)
    }

    /// The native sessions' MCP pass-through, with gh_mcp answered in it
    /// when `gh` is set and no upstream is named gh.
    private static func startMCP(_ mcp: AgentProxySettings.MCP, gh: AgentProxySettings.GH?, places: Places, secrets: any SecretStore,
                                 log: @escaping @Sendable (String) -> Void) -> NativeMCPProxy? {
        guard (1...65535).contains(mcp.port) else {
            log("agentProxy.mcp's port \(mcp.port) isn't a port: no MCP pass-through")
            return nil
        }
        let upstreams = mcp.upstreams.map { given in
            NativeMCPProxy.Endpoint(name: given.name, url: given.url, headers: given.headers, secretHeaders: given.secretHeaders,
                                    withheldTools: given.withheldTools)
        }
        var inProcess: [String: any InProcessMCP] = [:]
        if let gh {
            if upstreams.contains(where: { $0.name == GitHubMCP.name }) {
                log("agentProxy.gh is set, but mcp's upstream gh is passed through still: remove it for gh_mcp in-process")
            } else if let served = gitHubMCP(gh, places: places, log: log) {
                inProcess[GitHubMCP.name] = served
            }
        }
        let token = KeptSecret(AgentProxySettings.mcpTokenName, in: secrets)
        guard let proxy = NativeMCPProxy(port: UInt16(mcp.port), endpoints: { upstreams }, admits: { token.admits($0) },
                                         secret: { upstream, header in
                                             secrets.get(AgentProxySettings.secretKey(AgentProxySettings.mcpSecretName(upstream: upstream,
                                                                                                                       header: header)))
                                         }, inProcess: inProcess) else {
            log("loopback port \(mcp.port) can't be had for the MCP pass-through (another listener on it?)")
            return nil
        }
        proxy.start()
        let served = upstreams.map { "/mcp/\($0.name)" } + inProcess.keys.sorted().map { "/mcp/\($0) (in-process)" }
        log("the MCP pass-through is on loopback port \(mcp.port): "
            + (served.isEmpty ? "no upstreams" : served.joined(separator: ", "))
            + (token.isSet ? "" : "; no sessions' token yet (agent-proxy secret-set mcp/token): every call refused"))
        return proxy
    }

    /// The settings' dial-ins, each name a DNS label and each port one; any
    /// other passed over (said in the log, at the start).
    static func dialIns(_ settings: AgentProxySettings, log: (@Sendable (String) -> Void)?) -> [DialIn] {
        settings.dialIns.compactMap { given in
            guard DialIn.isName(given.name), (1...65535).contains(given.port), (1...65535).contains(given.hostPort) else {
                log?("dial-in \(given.name):\(given.port) passed over: a name of lower-case letters, digits and hyphens, and ports from 1 to 65535")
                return nil
            }
            return DialIn(name: given.name, port: given.port, hostPort: given.hostPort)
        }
    }

    // MARK: The settings, as agent-proxy reads them

    /// The file can't be read as settings.
    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    /// settings.json's `agentProxy`: nil when the file or its `agentProxy`
    /// isn't there; throws when the file is there and it can't be read
    /// (not JSON, or an `agentProxy` that isn't one).
    static func configured(at file: URL) throws -> AgentProxySettings? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw Unreadable(description: "\(file.path) can't be read: \(error)") }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Unreadable(description: "\(file.path) isn't a JSON object")
        }
        guard let given = object["agentProxy"], !(given is NSNull) else { return nil }
        do {
            return try JSONDecoder().decode(AgentProxySettings.self, from: JSONSerialization.data(withJSONObject: given))
        } catch {
            throw Unreadable(description: "\(file.path)'s agentProxy can't be read: \(error)")
        }
    }

    /// Whether settings.json has an `agentProxy`; nil when it can't be read
    /// (nothing is stopped on what isn't known).
    public static func isConfigured(_ places: Places) -> Bool? {
        do { return try configured(at: places.settingsFile) != nil } catch { return nil }
    }

    /// What agent-proxy starts with: settings.json's `agentProxy`, kept as
    /// the last good (0600); or, when settings.json is there and can't be
    /// read (a typo), the last good, so a restart while it's broken doesn't
    /// leave every container's egress down (`kept` true). Nil: no
    /// `agentProxy`, and nothing kept to stand in.
    public static func loadKeeping(_ places: Places) -> (settings: AgentProxySettings, kept: Bool)? {
        do {
            guard let settings = try configured(at: places.settingsFile) else { return nil }
            if let data = try? JSONEncoder().encode(settings) {
                try? FileManager.default.createDirectory(at: places.folder, withIntermediateDirectories: true)
                if (try? data.write(to: places.keptFile, options: .atomic)) != nil {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: places.keptFile.path)
                }
            }
            return (settings, false)
        } catch {
            guard let data = try? Data(contentsOf: places.keptFile),
                  let kept = try? JSONDecoder().decode(AgentProxySettings.self, from: data) else { return nil }
            return (kept, true)
        }
    }

    /// A digest of `settings`, as the launchd job's plist carries it: a job
    /// of other settings is started again (AgentProxyJob).
    public static func digest(_ settings: AgentProxySettings?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(settings)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

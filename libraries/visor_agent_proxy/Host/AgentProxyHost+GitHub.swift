// gh_mcp's server made from `agentProxy.gh` (GitHubMCP): its tokens from
// agent-token (`<agentToken> token <agent> --owner <owner>`, as gh_mcp ran
// it), kept by a TokenCache; its audit log in the server's logs folder
// unless the settings name another file. Which repositories and which
// session acts as which app are read again from settings.json at each
// call, as the dial-ins are at each CONNECT, so a session's app given in
// `sessionAgents` counts at its next call without a restart; agent-token's
// path and the log's are what agent-proxy started with.

import Foundation
import VisorAgentProxy
import VisorGHMCP
import VisorServer

extension AgentProxyHost {
    /// gh_mcp served from `settings`, logging to `places`' audit log unless
    /// they name another; nil when its `agent` names no app agent-token
    /// knows (said in the log).
    static func gitHubMCP(_ settings: AgentProxySettings.GH, places: Places, home: String = homeDirectory(),
                          log: @escaping @Sendable (String) -> Void) -> GitHubMCP? {
        guard let initial = configuration(settings, log: log) else { return nil }
        let settingsFile = places.settingsFile
        let configuration: @Sendable () -> MCPServer.Configuration = {
            guard let current = (try? configured(at: settingsFile)).flatMap({ $0 })?.gh else { return initial }
            return Self.configuration(current, log: nil) ?? initial
        }
        let agentToken = expandingTilde(settings.agentToken ?? AgentProxySettings.GH.defaultAgentToken, home: home)
        let auditLog = expandingTilde(settings.auditLog ?? places.ghAuditLog, home: home)
        let services = Services(transport: URLSessionTransport(), tokens: TokenCache(source: AgentTokenCommand(path: agentToken)))
        let calls = CallLog(path: auditLog)
        calls.note("\(serverVersion) in agent-proxy at /mcp/\(GitHubMCP.name); repositories \(initial.repositories.joined(separator: ",")); "
            + "agent logan-shire-\(initial.agent), \(initial.sessionAgents.count) sessions' own; agent-token \(agentToken)")
        log("gh_mcp is at /mcp/\(GitHubMCP.name) as logan-shire-\(initial.agent) (\(initial.sessionAgents.count) sessions' own), "
            + "touching \(initial.repositories.joined(separator: ", ")), its tokens from \(agentToken), its calls logged to \(auditLog)"
            + (FileManager.default.isExecutableFile(atPath: agentToken) ? "" : "; \(agentToken) isn't there: every call that needs GitHub fails"))
        return GitHubMCP(server: MCPServer(configuration: configuration, services: services, log: calls))
    }

    /// What gh_mcp's calls may touch and whom they act as, from the
    /// settings: nil when `agent` names no app agent-token knows. A
    /// session's app that names none is passed over (said in `log`).
    static func configuration(_ settings: AgentProxySettings.GH, log: (@Sendable (String) -> Void)?) -> MCPServer.Configuration? {
        let given = settings.agent ?? AgentProxySettings.GH.defaultAgent
        guard let agent = AgentApps.agent(given) else {
            log?("agentProxy.gh's agent \(given) isn't logan-shire-claude, -codex or -agent: no /mcp/\(GitHubMCP.name)")
            return nil
        }
        var sessionAgents: [String: String] = [:]
        for (session, app) in settings.sessionAgents.sorted(by: { $0.key < $1.key }) {
            guard let named = AgentApps.agent(app) else {
                log?("agentProxy.gh's sessionAgents: \(session)'s \(app) passed over: not logan-shire-claude, -codex or -agent")
                continue
            }
            sessionAgents[session] = named
        }
        return MCPServer.Configuration(repositories: settings.repositories ?? AgentProxySettings.GH.defaultRepositories, agent: agent,
                                       sessionAgents: sessionAgents)
    }
}

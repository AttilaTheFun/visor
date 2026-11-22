// gh_mcp's settings as each call reads them (GitHubMCP): which repositories,
// and which session acts as which app, read again from settings.json, so a
// session given its own app in `sessionAgents` counts at its next call
// without a restart. Where they can't be read (settings.json broken, its
// `gh` gone, an `agent` agent-token doesn't know), the last good stand in,
// said once in the log until they can be read again. Taking `gh` out of
// settings.json stops nothing: gh_mcp goes with agent-proxy's next start.

import Foundation
import Synchronization
import VisorGHMCP
import VisorServer

final class GitHubMCPSettings: Sendable {
    private let file: URL
    private let log: @Sendable (String) -> Void
    /// The last good, and whether a fallback to it has been said.
    private let kept: Mutex<(good: MCPServer.Configuration, said: Bool)>

    init(file: URL, initial: MCPServer.Configuration, log: @escaping @Sendable (String) -> Void) {
        self.file = file
        self.log = log
        kept = Mutex((initial, false))
    }

    /// The settings now, else the last good.
    func current() -> MCPServer.Configuration {
        let read: MCPServer.Configuration?
        let why: String
        do {
            if let gh = try AgentProxyHost.configured(at: file)?.gh {
                read = AgentProxyHost.configuration(gh, log: nil)
                why = "its agent isn't logan-shire-claude, -codex or -agent"
            } else {
                read = nil
                why = "it has no agentProxy.gh (taking gh_mcp out takes a restart)"
            }
        } catch {
            read = nil
            why = "it can't be read"
        }
        let (good, say) = kept.withLock { kept -> (MCPServer.Configuration, Bool) in
            if let read {
                kept = (read, false)
                return (read, false)
            }
            let say = !kept.said
            kept.said = true
            return (kept.good, say)
        }
        if say { log("gh_mcp: \(file.path)'s agentProxy.gh can't be used (\(why)): the last good stands in until it can") }
        return good
    }
}

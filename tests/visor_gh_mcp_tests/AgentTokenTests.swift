// Tokens, per agent, as gh_mcp had them: agent-token run as gh_mcp ran it
// (`<agentToken> token <agent> --owner <owner>`), a fake one here; each
// session acting as its own app (the settings' sessionAgents, by its
// CLIENT_ID), the rest as the settings' agent (logan-shire-agent unless
// said); a token kept for four minutes, and dropped when GitHub refuses it.

import Foundation
import Synchronization
import Testing
@testable import VisorGHMCP

@Test func tokenCacheAsksAgentTokenOnce() async throws {
    let folder = temporaryFolder()
    let script = try fakeAgentToken(in: folder)
    final class Clock: Sendable {
        let time = Mutex(Date(timeIntervalSince1970: 0))
    }
    let clock = Clock()
    let cache = TokenCache(source: AgentTokenCommand(path: script), maxAge: 240, now: { clock.time.withLock { $0 } })
    #expect(try await cache.token(agent: "claude", owner: "AttilaTheFun") == "ghs_fakeclaude1")
    #expect(try await cache.token(agent: "claude", owner: "attilathefun") == "ghs_fakeclaude1")
    #expect(try String(contentsOfFile: folder + "/calls", encoding: .utf8) == "token claude --owner AttilaTheFun\n")
    #expect(try await cache.token(agent: "codex", owner: "AttilaTheFun") == "ghs_fakecodex2")
    clock.time.withLock { $0 = Date(timeIntervalSince1970: 300) }
    #expect(try await cache.token(agent: "claude", owner: "AttilaTheFun") == "ghs_fakeclaude3")
    await cache.invalidate(agent: "claude", owner: "AttilaTheFun", token: "ghs_fakeclaude3")
    #expect(try await cache.token(agent: "claude", owner: "AttilaTheFun") == "ghs_fakeclaude4")
    await #expect(throws: ToolError.self) { try await cache.token(agent: "broken", owner: "AttilaTheFun") }
    let missing = AgentTokenCommand(path: folder + "/none")
    await #expect(throws: ToolError.self) { try await missing.token(agent: "agent", owner: "AttilaTheFun") }
}

@Test func eachSessionActsAsItsOwnApp() async throws {
    let folder = temporaryFolder()
    let script = try fakeAgentToken(in: folder)
    let transport = FakeTransport(["GET /repos/AttilaTheFun/oss/pulls/3": (200, ["number": 3, "title": "t"]),
                                   "GET /repos/AttilaTheFun/oss/pulls/3/reviews": (200, [])])
    let configuration = MCPServer.Configuration(agent: "agent", sessionAgents: ["s-claude": "claude", "s-codex": "codex"])
    let server = makeServer(transport: transport, configuration: configuration,
                            tokens: TokenCache(source: AgentTokenCommand(path: script)))
    for client in ["s-claude", "s-codex", "s-other", nil] {
        let viewed = await call(server, "pr_view", ["repo": "AttilaTheFun/oss", "number": 3], client: client)
        #expect(!viewed.isError, "\(client ?? "-"): \(viewed.text)")
    }
    let calls = try String(contentsOfFile: folder + "/calls", encoding: .utf8).split(separator: "\n")
    #expect(calls == ["token claude --owner AttilaTheFun", "token codex --owner AttilaTheFun", "token agent --owner AttilaTheFun"],
            "agent-token run as gh_mcp ran it, once an agent (its token kept)")
    #expect(Set(transport.tokens) == ["ghs_fakeclaude1", "ghs_fakecodex2", "ghs_fakeagent3"])
    #expect(transport.tokens.first == "ghs_fakeclaude1" && transport.tokens.last == "ghs_fakeagent3",
            "a session with no app of its own, or no CLIENT_ID, is the settings' agent")
}

@Test func appsAreNamedEitherWay() {
    #expect(AgentApps.agent("logan-shire-claude") == "claude")
    #expect(AgentApps.agent("codex") == "codex")
    #expect(AgentApps.agent("logan-shire-agent") == "agent")
    for wrong in ["logan-shire-gpt", "", "logan-shire-", "Claude", "shire-agent"] { #expect(AgentApps.agent(wrong) == nil, "\(wrong)") }
    #expect(MCPServer.Configuration(agent: "agent", sessionAgents: ["s1": "codex"]).agent(for: "s1") == "codex")
    #expect(MCPServer.Configuration(agent: "agent", sessionAgents: ["s1": "codex"]).agent(for: nil) == "agent")
}

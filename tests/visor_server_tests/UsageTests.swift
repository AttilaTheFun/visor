// What a session has used and how near its account's limits are: read
// from each agent's own output, added up across the agent's launches, and
// kept per agent on the server, which sends it with the catalogs.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class UsageTests: ServerTestCase {
    private var server: VisorServer!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-usage-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7979)
        server.exposure = FakeExposure()
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func record(_ id: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: id, created: 0),
                      process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
    }

    /// Claude Code's result carries the run's totals over every model, and
    /// the cost it reckons; its init says whether a key or a login pays.
    func testClaudeSaysWhatARunUsedAndHowItIsPaidFor() {
        let result = """
            {"type":"result","subtype":"success","is_error":false,"result":"two","total_cost_usd":0.0237632,\
            "modelUsage":{"claude-haiku-4-5":{"inputTokens":20,"outputTokens":88,"cacheReadInputTokens":35252,"cacheCreationInputTokens":9889,"costUSD":0.02},\
            "claude-opus-5-5":{"inputTokens":5,"outputTokens":12,"cacheReadInputTokens":0,"cacheCreationInputTokens":100,"costUSD":0.0037632}}}
            """
        XCTAssertEqual(ClaudeOutput.parse(result),
                       [.result(failure: nil, spent: SessionUsage(input: 20 + 35252 + 9889 + 5 + 100, cached: 35252, output: 100, cost: 0.0237632))])
        // An older openrouter CLI says nothing of it.
        XCTAssertEqual(ClaudeOutput.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#),
                       [.result(failure: nil, spent: nil)])
        XCTAssertEqual(ClaudeOutput.parse(#"{"type":"system","subtype":"init","session_id":"s","model":"m","apiKeySource":"none"}"#),
                       [.began(session: "s", model: "m", keySource: "none")])
    }

    /// A subscription's windows, five-hour first, then the week, then any
    /// other; an older event that names one window gives that one.
    func testClaudesRateLimitEventIsTheSubscriptionsWindows() {
        let event = """
            {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1791147600,"rateLimitType":"seven_day",\
            "utilization":0.82,"unifiedWindows":{"seven_day_opus":{"utilization":0.5,"resetsAt":1791147600},\
            "seven_day":{"utilization":0.82,"resetsAt":1791147600},"five_hour":{"utilization":0,"resetsAt":1791102000}}}}
            """
        XCTAssertEqual(ClaudeOutput.parse(event), [.limits([
            UsageLimit(name: "5-hour", used: 0, resets: 1_791_102_000),
            UsageLimit(name: "Weekly", used: 0.82, resets: 1_791_147_600),
            UsageLimit(name: "Weekly (Opus)", used: 0.5, resets: 1_791_147_600),
        ])])
        let older = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1791102000,"rateLimitType":"five_hour","utilization":0.25}}"#
        XCTAssertEqual(ClaudeOutput.parse(older), [.limits([UsageLimit(name: "5-hour", used: 0.25, resets: 1_791_102_000)])])
    }

    /// The openrouter CLI's key and credits, in dollars: the key's limit
    /// when it has one, and the credits left.
    func testTheOpenRouterKeysLimitAndCredits() throws {
        let line = """
            {"type":"system","subtype":"usage_limits","key":{"limit":10,"limit_remaining":8.5,"limit_reset":null,"usage":1.5},\
            "credits":{"total_credits":20,"total_usage":5}}
            """
        XCTAssertEqual(ClaudeOutput.parse(line), [.limits([
            UsageLimit(name: "Key limit", used: 0.15, left: 8.5, total: 10, unit: .dollars),
            UsageLimit(name: "Credits", used: 0.25, left: 15, total: 20, unit: .dollars),
        ])])
        // A key without a limit is only its credits.
        let unlimited = #"{"type":"system","subtype":"usage_limits","key":{"limit":null,"usage":1.5},"credits":{"total_credits":20,"total_usage":5}}"#
        XCTAssertEqual(ClaudeOutput.parse(unlimited).count, 1)
        // A monthly limit starts over on the first, at midnight UTC.
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z"))
        XCTAssertEqual(ClaudeOutput.nextReset("monthly", after: now), ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")?.timeIntervalSince1970)
        XCTAssertEqual(ClaudeOutput.nextReset("weekly", after: now), ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")?.timeIntervalSince1970)
    }

    /// Codex: the last request's tokens are the context, the total is the
    /// thread's; its account reads say the plan and the windows, and a
    /// sparse update keeps what it leaves out.
    func testCodexSaysItsTokensPlanAndWindows() throws {
        let tokens = """
            {"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"u","tokenUsage":{"modelContextWindow":258400,\
            "last":{"inputTokens":9000,"cachedInputTokens":8000,"outputTokens":500,"reasoningOutputTokens":200,"totalTokens":9500},\
            "total":{"inputTokens":40000,"cachedInputTokens":30000,"outputTokens":2000,"reasoningOutputTokens":800,"totalTokens":42000}}}}
            """
        let parsed = CodexOutput.parse(tokens)
        guard parsed.count == 2, case .tokens(let used, let limit) = parsed[0], case .spent(let spent) = parsed[1] else {
            return XCTFail("\(parsed)")
        }
        XCTAssertEqual(used, 9500)
        XCTAssertEqual(limit, 258_400)
        XCTAssertEqual(spent, SessionUsage(input: 40000, cached: 30000, output: 2000))

        let account = #"{"id":2,"result":{"account":{"type":"chatgpt","planType":"pro"},"requiresOpenaiAuth":true}}"#
        guard case .plan(let plan, let subscription) = CodexOutput.parse(account).last else { return XCTFail() }
        XCTAssertEqual(plan, "ChatGPT Pro")
        XCTAssertTrue(subscription)

        let read = """
            {"id":3,"result":{"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1791654291},\
            "secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1791102000},"credits":{"hasCredits":true,"unlimited":false,"balance":"62500"}}}}
            """
        guard case .rateLimits(let first) = CodexOutput.parse(read).last else { return XCTFail() }
        let update = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"secondary":{"usedPercent":45,"windowDurationMins":300}}}}"#
        guard case .rateLimits(let sparse) = CodexOutput.parse(update).first else { return XCTFail() }
        XCTAssertEqual(sparse.merged(over: first).limits, [
            UsageLimit(name: "Weekly", used: 0.17, resets: 1_791_654_291),
            UsageLimit(name: "5-hour", used: 0.45),
            UsageLimit(name: "Credits", left: 62500, unit: .credits),
        ])
    }

    /// The agent's running totals, added up: a total that carries on adds
    /// its difference, one that started over (a new launch that did not
    /// restore the count) adds the whole of it — and what was last
    /// reported survives a restart of the server, so a restored count is
    /// not counted twice.
    func testASessionsUsageAddsUpAcrossLaunches() throws {
        let session = record("A")
        server.sessions = [session]
        server.handle(.spent(SessionUsage(input: 100, cached: 50, output: 10, cost: 0.5)), from: session)
        server.handle(.spent(SessionUsage(input: 300, cached: 200, output: 30, cost: 1.5)), from: session)
        XCTAssertEqual(session.info.usage, SessionUsage(input: 300, cached: 200, output: 30, cost: 1.5))
        // Launched again, counting from nothing.
        server.handle(.spent(SessionUsage(input: 40, cached: 0, output: 5, cost: 0.25)), from: session)
        XCTAssertEqual(session.info.usage, SessionUsage(input: 340, cached: 200, output: 35, cost: 1.75))

        let stored = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(session.stored))
        XCTAssertEqual(stored.reportedUsage, SessionUsage(input: 40, cached: 0, output: 5, cost: 0.25))
        XCTAssertEqual(stored.info.usage, session.info.usage)
        // And to the clients, through JSON.
        XCTAssertEqual(SessionInfo(json: session.info.json)?.usage, session.info.usage)
    }

    /// An agent's plan and limits are the server's, kept on disk, and go
    /// out with its catalog; a plan that becomes a key drops the
    /// subscription's windows.
    func testAnAgentsAccountGoesWithItsCatalog() throws {
        server.harnesses = AgentHarnesses([ClaudeHarness(kind: .claude, tool: "claude", models: [])])
        let session = record("A")
        server.sessions = [session]
        server.handle(.plan("Subscription", subscription: true), from: session)
        server.handle(.limits([UsageLimit(name: "5-hour", used: 0.22, resets: 1_791_102_000)]), from: session)

        let catalog = try XCTUnwrap(server.catalogs().first { $0.agent == .claude })
        XCTAssertEqual(catalog.account?.plan, "Subscription")
        XCTAssertEqual(catalog.account?.limits.first?.used, 0.22)
        let wire = try XCTUnwrap(Envelope.decode(Envelope.catalogs([catalog]).encoded())?.catalogs?.first)
        XCTAssertEqual(wire.account, catalog.account)
        XCTAssertEqual(VisorServer.keptAccounts()[.claude], catalog.account, "kept for the next launch")

        server.handle(.plan("API key", subscription: false), from: session)
        XCTAssertEqual(server.account(for: .claude)?.limits, [])
    }
}

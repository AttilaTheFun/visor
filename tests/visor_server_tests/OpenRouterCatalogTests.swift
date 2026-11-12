// OpenRouter is the `openrouter` CLI's business: its sessions on disk are
// what Visor lists and resumes, its config's model is the default offered,
// and nothing about its key is Visor's.

@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class OpenRouterCatalogTests {
    private var home: URL!

    init() async throws {
        TestPlatform.install()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("visor-openrouter-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        setenv("OPENROUTER_HOME", home.path, 1)
    }

    isolated deinit {
        unsetenv("OPENROUTER_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ name: String, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: home.appendingPathComponent(name))
    }

    @Test func testSessionsListByFolderAndReadAsRows() throws {
        try write("sessions/aaa.json", [
            "id": "aaa", "cwd": "/tmp/project", "model": "m", "created": 1, "updated": 20,
            "messages": [
                ["role": "user", "content": "Add a README\nwith details"],
                ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "type": "function", "function": ["name": "bash", "arguments": "{\"command\":\"ls -la\"}"]]]],
                ["role": "tool", "content": "README.md\n[exit 0]", "tool_call_id": "c1", "name": "bash"],
                ["role": "assistant", "content": "Done."],
            ],
        ])
        try write("sessions/bbb.json", ["id": "bbb", "cwd": "/tmp/other", "model": "m", "created": 1, "updated": 30, "messages": []])

        let here = SessionCatalog.resumable(agent: .openrouter, cwd: "/tmp/project")
        #expect(here.map(\.id) == ["aaa"])
        #expect((here.first?.title) == "Add a README")
        #expect((SessionCatalog.resumable(agent: .openrouter, cwd: "").map(\.id)) == ["bbb", "aaa"])

        let rows = SessionCatalog.transcript(agent: .openrouter, id: "aaa", cwd: "/tmp/project")
        #expect(rows.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect((rows[1].activities) == ["bash: ls -la"])
        #expect((rows[2].toolName) == "tool_result")
        #expect((rows[3].text) == "Done.")
    }

    @Test func testCatalogReadsTheCLIsModelsWithPrices() throws {
        let harness = OpenRouterHarness()
        // No list on disk yet: a stand-in.
        #expect(harness.catalog().defaultModel == "openai/gpt-5-nano")

        func model(_ id: String, _ name: String, _ prompt: String, _ completion: String, created: Double, tools: Bool = true) -> [String: Any] {
            ["id": id, "name": name, "created": created, "pricing": ["prompt": prompt, "completion": completion],
             "supported_parameters": tools ? ["tools", "reasoning"] : ["temperature"]]
        }
        try write("models.json", ["fetched": 1, "models": [
            model("openai/gpt-old", "OpenAI: GPT Old", "0.000001", "0.000002", created: 1),
            model("openai/gpt-new", "OpenAI: GPT New", "0.00000005", "0.0000004", created: 2),
            model("openai/gpt-new:batch", "OpenAI: GPT New (batch)", "0.00000002", "0.0000002", created: 3),
            model("acme/free-one:free", "Acme: Free One", "0", "0", created: 5),
            model("acme/no-tools", "Acme: No Tools", "0.000001", "0.000001", created: 9, tools: false),
            model("zeta/other", "Zeta: Other", "0.000003", "0.000015", created: 4),
            model("openai/gpt-5-nano", "OpenAI: GPT-5 Nano", "0.00000005", "0.0000004", created: 0),
        ]])
        var catalog = harness.catalog()
        // Tool-callers only; the short list is the default and the
        // hand-kept coding list (none of which this file has).
        #expect(!(catalog.models.contains { $0.id == "acme/no-tools" }))
        #expect((catalog.models.filter(\.listed).map(\.id)) == [])
        let new = try #require(catalog.models.first { $0.id == "openai/gpt-new" })
        #expect(new.title == "GPT New")
        #expect(new.group == "OpenAI")
        #expect(new.subtitle == "$0.050 in · $0.40 out per M tokens")
        #expect(new.efforts == ["low", "medium", "high"])
        #expect((catalog.models.first { $0.id == "acme/free-one:free" }?.subtitle) == "Free")
        #expect(catalog.defaultModel == "openai/gpt-5-nano")

        // The coding list's models, when offered, follow in its order.
        var file = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("models.json"))) as! [String: Any]
        var models = file["models"] as! [[String: Any]]
        models.append(model(OpenRouterHarness.coding[1], "DeepSeek: Second", "0.0000001", "0.0000002", created: 6))
        models.append(model(OpenRouterHarness.coding[0], "Z.ai: First", "0.0000001", "0.0000002", created: 7))
        file["models"] = models
        try write("models.json", file)
        #expect((harness.catalog().models.filter(\.listed).map(\.id)) == ([OpenRouterHarness.coding[0], OpenRouterHarness.coding[1]]))

        // The CLI's configured model leads, and is the default.
        try write("config.json", ["apiKey": "sk-or-secret", "model": "zeta/other"])
        catalog = harness.catalog()
        #expect(catalog.defaultModel == "zeta/other")
        // The default is not a suggestion unless it is one.
        #expect(!(catalog.models.first { $0.id == "zeta/other" }?.listed ?? true))
        // The catalog says nothing about the key.
        #expect(!(Envelope.catalogs([catalog]).encoded().contains("sk-or-")))
        // And the flags survive the wire.
        let decoded = Envelope.decode(Envelope.catalogs([catalog]).encoded())?.catalogs?.first
        #expect((decoded?.models.filter(\.listed).count) == catalog.models.filter(\.listed).count)
        #expect((decoded?.models.first { $0.id == "openai/gpt-old" }?.group) == "OpenAI")
    }

    @MainActor
    @Test func testBackendDrivesTheCLIAsClaude() {
        let process = OpenRouterHarness().makeProcess(cwd: "/tmp", skipPermissions: true, resume: "abc")
        #expect(process is ClaudeProcess)
        #expect(process.resumeCommand == "cd /tmp && openrouter --resume abc")
    }
}
}

/// Claude Code's own model list, as `initialize` answers it.
extension ServerTests {
@Suite @MainActor final class ClaudeModelsTests {
    @Test func testInitializeModelsBecomeTheCatalog() throws {
        let list: [[String: Any]] = [
            ["value": "default", "resolvedModel": "claude-opus-5-5[1m]", "displayName": "Default (recommended)",
             "description": "Opus 5.5 with 1M context · Best for everyday, complex tasks", "supportedEffortLevels": ["low", "high"]],
            ["value": "opus[1m]", "resolvedModel": "claude-opus-5-5[1m]", "displayName": "Opus (1M context)",
             "description": "Opus 5.5 with 1M context · Best for everyday, complex tasks", "supportedEffortLevels": ["low", "high"]],
            ["value": "claude-fable-5-1[1m]", "resolvedModel": "claude-fable-5-1", "displayName": "Fable",
             "description": "Fable 5.1 · Most capable", "supportedEffortLevels": ["low", "max"]],
            ["value": "haiku", "resolvedModel": "claude-haiku-4-5-20251001", "displayName": "Haiku",
             "description": "Haiku 4.5 · Fastest for quick answers"],
        ]
        let parsed = try #require(ClaudeHarness.parse(models: list))
        #expect(parsed.models.map(\.id) == (["opus[1m]", "claude-fable-5-1[1m]", "haiku"]))
        #expect(parsed.models.map(\.title) == ["Opus 5.5", "Fable 5.1", "Haiku 4.5"])
        #expect((parsed.models[0].subtitle) == "Best for everyday, complex tasks · 1M context")
        #expect((parsed.models[2].efforts) == [])
        #expect(parsed.defaultModel == "opus[1m]")

        let catalog = AgentCatalog(agent: .claude, models: parsed.models, defaultModel: parsed.defaultModel)
        // No choice yet: the default. What a turn reports, and the names
        // older sessions kept, reach the same models.
        #expect((catalog.model(matching: nil)?.id) == "opus[1m]")
        #expect((catalog.model(matching: "claude-opus-5-5")?.id) == "opus[1m]")
        #expect((catalog.model(matching: "claude-fable-5-1")?.id) == "claude-fable-5-1[1m]")
        #expect((catalog.model(matching: "fable")?.id) == "claude-fable-5-1[1m]")
        #expect(catalog.title(for: nil) == "Opus 5.5")
    }
}
}

/// The newer shape of Claude Code's list: the name as the display name,
/// only the tagline in the description.
extension ServerTests {
@Suite @MainActor final class ClaudeModelsNewShapeTests {
    @Test func testNameFromTheDisplayName() throws {
        let list: [[String: Any]] = [
            ["value": "default", "resolvedModel": "claude-opus-5-5", "displayName": "Default (recommended)",
             "description": "Opus 5.5 · Best for everyday, complex tasks"],
            ["value": "opus", "resolvedModel": "claude-opus-5-5", "displayName": "Opus 5.5",
             "description": "Most capable for ambitious work", "supportedEffortLevels": ["low", "high"]],
            ["value": "claude-fable-5-1", "resolvedModel": "claude-fable-5-1", "displayName": "Fable 5.1",
             "description": "For your toughest challenges"],
            // No version anywhere: the model's own id names it.
            ["value": "sonnet", "resolvedModel": "claude-sonnet-5", "displayName": "Sonnet",
             "description": "Most efficient for everyday tasks"],
        ]
        let parsed = try #require(ClaudeHarness.parse(models: list))
        #expect(parsed.models.map(\.title) == ["Opus 5.5", "Fable 5.1", "Sonnet 5"])
        #expect(parsed.models.map(\.subtitle) == ["Most capable for ambitious work", "For your toughest challenges",
                                                        "Most efficient for everyday tasks"])
        #expect(parsed.defaultModel == "opus")
    }
}
}

/// Codex's own model list, as its app-server's `model/list` answers it.
extension ServerTests {
@Suite @MainActor final class CodexModelsTests {
    @Test func testModelListBecomesTheCatalog() {
        let list: [[String: Any]] = [
            ["id": "gpt-6-astra", "model": "gpt-6-astra", "displayName": "GPT-6-Astra", "description": "Frontier intelligence.",
             "hidden": false, "isDefault": true, "defaultReasoningEffort": "medium",
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"], ["reasoningEffort": "ultra"]]],
            ["id": "gpt-6-sol", "model": "gpt-6-sol", "displayName": "GPT-6-Sol", "description": "Workhorse.", "hidden": false,
             "supportedReasoningEfforts": [["reasoningEffort": "low"]]],
            ["id": "internal", "model": "internal", "displayName": "Internal", "hidden": true],
        ]
        let parsed = CodexHarness.parse(models: list)
        #expect(parsed.models.map(\.id) == ["gpt-6-astra", "gpt-6-sol"])
        #expect(parsed.models.map(\.title) == ["Astra 6", "Sol 6"])
        #expect((parsed.models[0].efforts) == ["low", "medium", "ultra"])
        #expect((parsed.models[0].defaultEffort) == "medium")
        #expect(parsed.defaultModel == "gpt-6-astra")
    }
}
}

/// The catalog says when the CLI has no key: the list still shows, and the
/// picker says why a session would fail.
extension ServerTests {
@Suite @MainActor final class OpenRouterLoginTests {
    @Test func testALoggedOutCLIIsSaid() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("visor-or-login-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("OPENROUTER_HOME", home.path, 1)
        defer { unsetenv("OPENROUTER_HOME"); try? FileManager.default.removeItem(at: home) }
        let saved = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
        unsetenv("OPENROUTER_API_KEY")
        defer { if let saved { setenv("OPENROUTER_API_KEY", saved, 1) } }
        #expect(!SessionCatalog.openrouterHasKey())
        try Data(#"{"apiKey":"sk-test"}"#.utf8).write(to: home.appendingPathComponent("config.json"))
        #expect(SessionCatalog.openrouterHasKey())
    }
}
}

/// Claude Code's list of models is replaced at once only by one that keeps
/// every model held (a new one may be added); one that drops models waits
/// for a second answer.
extension ServerTests {
@Suite @MainActor final class ClaudeModelListTests {
    private func model(_ id: String) -> AgentModel { AgentModel(id: id, title: id, efforts: []) }

    @Test func testAShorterListWaitsToBeConfirmed() {
        let full = ["opus", "claude-fable-5-1", "sonnet", "haiku"].map(model)
        let base = ["sonnet", "haiku"].map(model)
        #expect(ClaudeHarness.accepts(full, over: nil), "the first list is taken")
        #expect(ClaudeHarness.accepts(full, over: base), "a list that grows is taken at once")
        #expect(ClaudeHarness.accepts(full + [model("claude-opus-5-9")], over: full), "so is one that adds a model")
        #expect(!ClaudeHarness.accepts(base, over: full), "a list that loses Opus and Fable waits")
        #expect(ClaudeHarness.accepts(full, over: full))
    }
}
}

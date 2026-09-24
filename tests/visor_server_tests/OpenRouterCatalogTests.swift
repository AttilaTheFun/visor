// OpenRouter is the `openrouter` CLI's business: its sessions on disk are
// what Visor lists and resumes, its config's model is the default offered,
// and nothing about its key is Visor's.

import VisorProtocol
@testable import VisorServer
import XCTest

final class OpenRouterCatalogTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("visor-openrouter-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        setenv("OPENROUTER_HOME", home.path, 1)
    }

    override func tearDown() {
        unsetenv("OPENROUTER_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ name: String, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: home.appendingPathComponent(name))
    }

    func testSessionsListByFolderAndReadAsRows() throws {
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
        XCTAssertEqual(here.map(\.id), ["aaa"])
        XCTAssertEqual(here.first?.title, "Add a README")
        XCTAssertEqual(SessionCatalog.resumable(agent: .openrouter, cwd: "").map(\.id), ["bbb", "aaa"])

        let rows = SessionCatalog.transcript(agent: .openrouter, id: "aaa", cwd: "/tmp/project")
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(rows[1].activities, ["bash: ls -la"])
        XCTAssertEqual(rows[2].toolName, "tool_result")
        XCTAssertEqual(rows[3].text, "Done.")
    }

    func testCatalogReadsTheCLIsModelsWithPrices() throws {
        let backend = OpenRouterBackend()
        // No list on disk yet: a stand-in.
        XCTAssertEqual(backend.catalog().defaultModel, "openai/gpt-5-nano")

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
        var catalog = backend.catalog()
        // Tool-callers only; the short list is the default and the
        // hand-kept coding list (none of which this file has).
        XCTAssertFalse(catalog.models.contains { $0.id == "acme/no-tools" })
        XCTAssertEqual(catalog.models.filter(\.listed).map(\.id), [])
        let new = try XCTUnwrap(catalog.models.first { $0.id == "openai/gpt-new" })
        XCTAssertEqual(new.title, "GPT New")
        XCTAssertEqual(new.group, "OpenAI")
        XCTAssertEqual(new.subtitle, "$0.050 in · $0.40 out per M tokens")
        XCTAssertEqual(new.efforts, ["low", "medium", "high"])
        XCTAssertEqual(catalog.models.first { $0.id == "acme/free-one:free" }?.subtitle, "Free")
        XCTAssertEqual(catalog.defaultModel, "openai/gpt-5-nano")

        // The coding list's models, when offered, follow in its order.
        var file = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("models.json"))) as! [String: Any]
        var models = file["models"] as! [[String: Any]]
        models.append(model(OpenRouterBackend.coding[1], "DeepSeek: Second", "0.0000001", "0.0000002", created: 6))
        models.append(model(OpenRouterBackend.coding[0], "Z.ai: First", "0.0000001", "0.0000002", created: 7))
        file["models"] = models
        try write("models.json", file)
        XCTAssertEqual(backend.catalog().models.filter(\.listed).map(\.id),
                       [OpenRouterBackend.coding[0], OpenRouterBackend.coding[1]])

        // The CLI's configured model leads, and is the default.
        try write("config.json", ["apiKey": "sk-or-secret", "model": "zeta/other"])
        catalog = backend.catalog()
        XCTAssertEqual(catalog.defaultModel, "zeta/other")
        // The default is not a suggestion unless it is one.
        XCTAssertFalse(catalog.models.first { $0.id == "zeta/other" }?.listed ?? true)
        // The catalog says nothing about the key.
        XCTAssertFalse(Envelope.catalogs([catalog]).encoded().contains("sk-or-"))
        // And the flags survive the wire.
        let decoded = Envelope.decode(Envelope.catalogs([catalog]).encoded())?.catalogs?.first
        XCTAssertEqual(decoded?.models.filter(\.listed).count, catalog.models.filter(\.listed).count)
        XCTAssertEqual(decoded?.models.first { $0.id == "openai/gpt-old" }?.group, "OpenAI")
    }

    func testBackendDrivesTheCLIAsClaude() {
        let process = OpenRouterBackend().makeProcess(cwd: "/tmp", skipPermissions: true, resume: "abc")
        XCTAssertTrue(process is ClaudeProcess)
        XCTAssertEqual(process.resumeCommand, "cd /tmp && openrouter --resume abc")
    }
}

/// Claude Code's own model list, as `initialize` answers it.
final class ClaudeModelsTests: XCTestCase {
    func testInitializeModelsBecomeTheCatalog() throws {
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
        let parsed = try XCTUnwrap(ClaudeBackend.parse(models: list))
        XCTAssertEqual(parsed.models.map(\.id), ["opus[1m]", "claude-fable-5-1[1m]", "haiku"])
        XCTAssertEqual(parsed.models.map(\.title), ["Opus 5.5", "Fable 5.1", "Haiku 4.5"])
        XCTAssertEqual(parsed.models[0].subtitle, "Best for everyday, complex tasks · 1M context")
        XCTAssertEqual(parsed.models[2].efforts, [])
        XCTAssertEqual(parsed.defaultModel, "opus[1m]")

        let catalog = AgentCatalog(agent: .claude, models: parsed.models, defaultModel: parsed.defaultModel)
        // No choice yet: the default. What a turn reports, and the names
        // older sessions kept, reach the same models.
        XCTAssertEqual(catalog.model(matching: nil)?.id, "opus[1m]")
        XCTAssertEqual(catalog.model(matching: "claude-opus-5-5")?.id, "opus[1m]")
        XCTAssertEqual(catalog.model(matching: "claude-fable-5-1")?.id, "claude-fable-5-1[1m]")
        XCTAssertEqual(catalog.model(matching: "fable")?.id, "claude-fable-5-1[1m]")
        XCTAssertEqual(catalog.title(for: nil), "Opus 5.5")
    }
}

/// Codex's own model list, as its app-server's `model/list` answers it.
final class CodexModelsTests: XCTestCase {
    func testModelListBecomesTheCatalog() {
        let list: [[String: Any]] = [
            ["id": "gpt-6-astra", "model": "gpt-6-astra", "displayName": "GPT-6-Astra", "description": "Frontier intelligence.",
             "hidden": false, "isDefault": true, "defaultReasoningEffort": "medium",
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"], ["reasoningEffort": "ultra"]]],
            ["id": "gpt-6-sol", "model": "gpt-6-sol", "displayName": "GPT-6-Sol", "description": "Workhorse.", "hidden": false,
             "supportedReasoningEfforts": [["reasoningEffort": "low"]]],
            ["id": "internal", "model": "internal", "displayName": "Internal", "hidden": true],
        ]
        let parsed = CodexBackend.parse(models: list)
        XCTAssertEqual(parsed.models.map(\.id), ["gpt-6-astra", "gpt-6-sol"])
        XCTAssertEqual(parsed.models.map(\.title), ["Astra 6", "Sol 6"])
        XCTAssertEqual(parsed.models[0].efforts, ["low", "medium", "ultra"])
        XCTAssertEqual(parsed.models[0].defaultEffort, "medium")
        XCTAssertEqual(parsed.defaultModel, "gpt-6-astra")
    }
}

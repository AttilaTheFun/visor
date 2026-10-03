import Foundation
import Synchronization
import VisorProtocol

/// OpenRouter through the `openrouter` CLI (github.com/AttilaTheFun/
/// open_router_cli), which speaks Claude Code's stream-json protocol: it
/// is driven exactly as Claude is, resumed by its own session id, its
/// sessions kept in ~/.openrouter/sessions. Its key and default model are
/// its own business (`openrouter auth login`), like Claude's and Codex's
/// logins; Visor only runs it.
public final class OpenRouterHarness: AgentHarness {
    public let kind: AgentKind = .openrouter
    public let tool = "openrouter"

    public init() {}

    @MainActor public func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess {
        ClaudeProcess(cwd: cwd, skipPermissions: skipPermissions, resume: resume, tool: tool)
    }

    /// Every model OpenRouter offers that can call tools (the agent
    /// needs them), from the list the CLI keeps on disk
    /// (~/.openrouter/models.json), priced. The suggestions are `listed`:
    /// `coding`, a hand-kept copy of OpenRouter's programming collection;
    /// the rest are for All Models. The default is the model the CLI runs
    /// when none is named, suggested or not. With
    /// no list on disk yet, a few known models stand in.
    public func catalog() -> AgentCatalog {
        let configured = SessionCatalog.openrouterDefaultModel()
        // Without a key the list still shows (it is public), but a session
        // would fail at its first turn: said where the model is picked.
        let note = available && !SessionCatalog.openrouterHasKey()
            ? "The openrouter CLI is not logged in on this computer: run `openrouter auth login` in a terminal there." : nil
        guard let cached = Self.cachedModels(), !cached.isEmpty else {
            return AgentCatalog(agent: kind, models: Self.fallback, defaultModel: configured ?? Self.cliDefault, available: available,
                                note: note ?? "OpenRouter's model list has not been fetched on this computer yet; these are stand-ins.")
        }
        // What the CLI runs when no model is named: its config's, else
        // its own default.
        let runs = configured ?? Self.cliDefault
        var featured: [String] = []
        let offered = Set(cached.map(\.id))
        for id in Self.coding where offered.contains(id) && !featured.contains(id) { featured.append(id) }
        let rank = Dictionary(uniqueKeysWithValues: featured.enumerated().map { ($1, $0) })
        let models = cached.map { model in
            AgentModel(id: model.id, title: model.title, subtitle: model.price, efforts: model.reasoning ? ["low", "medium", "high"] : [],
                       group: model.group, listed: rank[model.id] != nil)
        }.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.group ?? "", a.title) < (b.group ?? "", b.title)
            }
        }
        return AgentCatalog(agent: kind, models: models, defaultModel: runs, available: available, note: note)
    }

    /// The openrouter CLI's own default model (`ORConfig.defaultModel`).
    static let cliDefault = "openai/gpt-5-nano"

    /// The short list: the top ten of OpenRouter's programming collection
    /// (openrouter.ai/collections/programming, the week's most used for
    /// coding), as it stood on 2026-09-24. Chosen by hand, in its order;
    /// update it from the page. A model OpenRouter drops simply falls out.
    static let coding = [
        "z-ai/glm-5.3-flash",
        "deepseek/deepseek-v4.1-flash",
        "nvidia/nemotron-3-ultra-550b-a55b:free",
        "xiaomi/mimo-v2.5",
        "deepseek/deepseek-v4-flash-0731",
        "tencent/hy4-preview",
        "z-ai/glm-5.3",
        "meta/muse-spark-1.3-contributor",
        "xiaomi/mimo-v2.6-flash",
        "openai/gpt-5.6-luna",
    ]

    /// What is offered before the CLI has written its model list.
    static let fallback = [
        AgentModel(id: "openai/gpt-5-nano", title: "GPT-5 Nano", subtitle: "OpenAI", efforts: ["low", "medium", "high"]),
        AgentModel(id: "qwen/qwen3.8-27b:free", title: "Qwen 3.8 27B (free)", subtitle: "Alibaba", efforts: []),
    ]

    /// One model from the CLI's list, as much of it as the picker needs.
    struct Cached {
        let id: String
        let title: String
        let group: String?
        let price: String?
        let free: Bool
        let reasoning: Bool
        let created: Double
    }

    /// The CLI's model list, the ones that can call tools.
    static func cachedModels() -> [Cached]? {
        let file = SessionCatalog.openrouterRoot.appendingPathComponent("models.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["models"] as? [[String: Any]] else { return nil }
        let models: [Cached] = list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let parameters = entry["supported_parameters"] as? [String] ?? []
            guard parameters.contains("tools") else { return nil }
            let name = entry["name"] as? String ?? id
            // "OpenAI: GPT-5 Nano" → maker "OpenAI", model "GPT-5 Nano".
            let parts = name.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let group = parts.count == 2 ? parts[0] : String(id.split(separator: "/").first ?? "")
            let title = parts.count == 2 ? parts[1] : name
            let pricing = entry["pricing"] as? [String: Any]
            let input = (pricing?["prompt"] as? String).flatMap(Double.init)
            let output = (pricing?["completion"] as? String).flatMap(Double.init)
            let free = id.hasSuffix(":free") || (input == 0 && output == 0)
            return Cached(id: id, title: title, group: group, price: price(input: input, output: output, free: free),
                          free: free, reasoning: parameters.contains("reasoning"), created: entry["created"] as? Double ?? 0)
        }
        return models
    }

    /// "$0.05 in · $0.40 out per M tokens", or "Free".
    static func price(input: Double?, output: Double?, free: Bool) -> String? {
        if free { return "Free" }
        guard let input, let output, input >= 0, output >= 0 else { return nil }
        func dollars(_ perToken: Double) -> String {
            let perMillion = perToken * 1_000_000
            let digits = perMillion < 0.1 ? 3 : 2
            var text = String(Int((perMillion * pow(10, Double(digits))).rounded()))
            while text.count <= digits { text = "0" + text }
            text.insert(".", at: text.index(text.endIndex, offsetBy: -digits))
            return "$" + text
        }
        return "\(dollars(input)) in · \(dollars(output)) out per M tokens"
    }

    /// Fetches the list through the CLI when it is missing or a day old:
    /// whether it did. Visor never calls OpenRouter itself.
    public static func refreshIfStale() async -> Bool {
        let file = SessionCatalog.openrouterRoot.appendingPathComponent("models.json")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        guard age == nil || age! > 24 * 60 * 60, let tool = ToolPath.resolve("openrouter") else { return false }
        return await Command.output(tool, ["models", "--refresh"], environment: ToolPath.environment())?.status == 0
    }
}

// A backend is one agent kind, and everything the server needs of it: how
// to make its process (a chat process, or its own terminal), what it can
// resume, a session's transcript, and its models. The server holds a set
// of backends and never branches on the agent itself — a different set is
// a different set of agents. A host swaps the registry to bring its own.

import Foundation
import VisorProtocol

public protocol AgentBackend: AnyObject, Sendable {
    /// Which agent this serves.
    var kind: AgentKind { get }
    /// The command-line tool it drives, for availability.
    var tool: String { get }
    /// The models it offers, and whether the tool is installed.
    func catalog() -> AgentCatalog
    /// A chat process for a session; resumes `resume` if given.
    func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess
    /// The agent's own terminal (a PTY process), for TUI mode; nil where
    /// the agent has no terminal to drive (OpenRouter).
    func makeTerminal(cwd: String, skipPermissions: Bool, resume: String?) -> (AgentProcess & TerminalCapable)?
    /// The sessions resumable in this folder.
    func resumable(cwd: String) -> [ResumableSession]
    /// A session's transcript, the newest `limit` rows.
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry]
    /// Makes the session's history findable where the folder now is; a
    /// no-op where the agent resumes by id regardless of folder.
    func adoptHistory(id: String, cwd: String)
}

public extension AgentBackend {
    /// Installed on the login shell's PATH.
    var available: Bool { ToolPath.resolve(tool) != nil }
    func adoptHistory(id: String, cwd: String) { _ = SessionCatalog.adoptHistory(agent: kind, id: id, cwd: cwd) }
    func resumable(cwd: String) -> [ResumableSession] { SessionCatalog.resumable(agent: kind, cwd: cwd) }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] {
        SessionCatalog.transcript(agent: kind, id: id, cwd: cwd, limit: limit)
    }
    func makeTerminal(cwd: String, skipPermissions: Bool, resume: String?) -> (AgentProcess & TerminalCapable)? {
        TerminalProcess(agent: kind, cwd: cwd, skipPermissions: skipPermissions, resume: resume)
    }
}

/// The agents the server serves. Injectable: a host assigns its own before
/// the server starts, and every seam — process, terminal, resumable list,
/// transcript, models — goes through whatever is registered here.
public final class AgentBackends: @unchecked Sendable {
    private let byKind: [AgentKind: AgentBackend]
    public let all: [AgentBackend]

    public init(_ list: [AgentBackend]) {
        all = list
        byKind = Dictionary(list.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func backend(for kind: AgentKind) -> AgentBackend? { byKind[kind] }

    /// Claude Code, Codex, and Ori (Claude Code's protocol under another
    /// tool). The set Visor ships with.
    public static let standard = AgentBackends([
        ClaudeBackend(kind: .claude, tool: "claude", models: [
            AgentModel(id: "fable", title: "Fable 5.1", subtitle: "The most intelligent model", efforts: ClaudeBackend.efforts),
            AgentModel(id: "opus", title: "Opus 5", subtitle: "Deep reasoning for complex work", efforts: ClaudeBackend.efforts),
            AgentModel(id: "sonnet", title: "Sonnet 5", subtitle: "Fast and capable for everyday tasks", efforts: ClaudeBackend.efforts),
            AgentModel(id: "haiku", title: "Haiku 4.5", subtitle: "The quickest, for light work", efforts: ClaudeBackend.efforts),
        ]),
        CodexBackend(),
        OpenRouterBackend(),
    ])
}

/// Claude Code, and anything that speaks its stream-json protocol under
/// another tool name (Ori).
public final class ClaudeBackend: AgentBackend, @unchecked Sendable {
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    public let kind: AgentKind
    public let tool: String
    private let models: [AgentModel]

    public init(kind: AgentKind, tool: String, models: [AgentModel]) {
        self.kind = kind
        self.tool = tool
        self.models = models
    }

    /// Claude Code's own list, as it answered `initialize` (its models,
    /// names, effort levels and which is the default for this account);
    /// the fixed list until it has answered.
    public func catalog() -> AgentCatalog {
        if tool == "claude", let asked = Self.asked.value {
            return AgentCatalog(agent: kind, models: asked.models, defaultModel: Self.configuredModel() ?? asked.defaultModel,
                                available: available)
        }
        return AgentCatalog(agent: kind, models: models, defaultModel: Self.configuredModel(), available: available)
    }

    /// What Claude Code last said of its models.
    static let asked = Locked<(models: [AgentModel], defaultModel: String?)?>(nil)

    /// Asks Claude Code for its models: `claude -p` with stream-json, the
    /// SDK's `initialize` control request, the answer's `models`, then
    /// the process is ended — no turn is run. Calls `done` when the list
    /// changed.
    public static func refreshModels(then done: @escaping @Sendable () -> Void) {
        guard let executable = ToolPath.resolve("claude") else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            p.environment = ToolPath.environment()
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let request = "{\"type\":\"control_request\",\"request_id\":\"visor-models\",\"request\":{\"subtype\":\"initialize\"}}\n"
            input.fileHandleForWriting.write(Data(request.utf8))
            // Never waits long: a Claude that does not answer is ended.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
            var buffer = Data()
            var answer: [String: Any]?
            while answer == nil {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["type"] as? String == "control_response",
                          let response = object["response"] as? [String: Any] else { continue }
                    answer = (response["response"] as? [String: Any]) ?? response
                    break
                }
            }
            try? input.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
            guard let list = answer?["models"] as? [[String: Any]], let parsed = parse(models: list), !parsed.models.isEmpty else { return }
            let changed = asked.value.map { $0.models != parsed.models || $0.defaultModel != parsed.defaultModel } ?? true
            asked.value = parsed
            if changed { done() }
        }
    }

    /// Claude Code's `models` as the catalog's: each model's value (what
    /// `--model` takes) as its id, its name ("Opus 5.5") as its title and
    /// its tagline as the subtitle; the "default" entry is not a model of
    /// its own but says which one is the default.
    ///
    /// Claude Code has written this two ways: the name first in the
    /// description ("Opus 5.5 with 1M context · Best for…") with a loose
    /// display name ("Opus (1M context)"), and now the name as the display
    /// name ("Opus 5.5") with only the tagline in the description. The
    /// title is whichever carries a version, else one made from the model.
    static func parse(models list: [[String: Any]]) -> (models: [AgentModel], defaultModel: String?)? {
        func versioned(_ text: String) -> Bool { text.contains { $0.isNumber } }
        var models: [AgentModel] = []
        var resolved: [String: String] = [:]
        var defaultResolved: String?
        for entry in list {
            guard let value = entry["value"] as? String else { continue }
            let target = entry["resolvedModel"] as? String
            if value == "default" { defaultResolved = target; continue }
            let description = (entry["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let display = (entry["displayName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var parts = description.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
            var notes: [String] = []
            var title: String
            if parts.count > 1, versioned(parts[0]) {
                title = parts.removeFirst()
            } else if versioned(display) {
                title = display
            } else {
                title = AgentCatalog.prettyModelName(target ?? value)
            }
            if title.hasSuffix(" with 1M context") { title = String(title.dropLast(" with 1M context".count)); notes.append("1M context") }
            if (value.contains("[1m]") || display.contains("1M")) && !notes.contains("1M context") { notes.append("1M context") }
            let tagline = parts.filter { !$0.isEmpty && $0 != title }
            let efforts = entry["supportedEffortLevels"] as? [String] ?? []
            let subtitle = (tagline + notes).joined(separator: " · ")
            models.append(AgentModel(id: value, title: title, subtitle: subtitle.isEmpty ? nil : subtitle, efforts: efforts))
            if let target, resolved[target] == nil { resolved[target] = value }
        }
        let defaultModel = defaultResolved.flatMap { resolved[$0] }
        return (models, defaultModel)
    }

    /// The model Claude Code is set to use (`model` in
    /// ~/.claude/settings.json, else ANTHROPIC_MODEL); nil leaves it to the
    /// account's default, which a session reports once it runs.
    static func configuredModel() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: file),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = object["model"] as? String, !model.isEmpty { return model }
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? ""
        return env.isEmpty ? nil : env
    }

    public func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess {
        ClaudeProcess(cwd: cwd, skipPermissions: skipPermissions, resume: resume, tool: tool)
    }
}

/// Codex through its app-server: one long-lived daemon per session, a
/// thread started or resumed by id, each message a turn, a turn
/// interrupted in place. (`CodexProcess`, one `codex exec` per turn, is
/// kept in the tree as the older driver but is not what this makes.)
public final class CodexBackend: AgentBackend, @unchecked Sendable {
    public let kind: AgentKind = .codex
    public let tool = "codex"

    public init() {}

    public func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess {
        CodexAppServerProcess(cwd: cwd, skipPermissions: skipPermissions, resume: resume)
    }

    /// Codex's own list, as its app-server answered `model/list`; its
    /// models cache on disk until then (and where it has no answer).
    public func catalog() -> AgentCatalog {
        var catalog = Self.catalog()
        if let asked = Self.asked.value, !asked.models.isEmpty {
            catalog.models = asked.models
            // A model set in config.toml wins over the account's default.
            if catalog.defaultModel == nil || !asked.models.contains(where: { $0.id == catalog.defaultModel }) {
                catalog.defaultModel = asked.defaultModel
            }
        }
        catalog.available = available
        return catalog
    }

    /// What Codex last said of its models.
    static let asked = Locked<(models: [AgentModel], defaultModel: String?)?>(nil)

    /// Asks Codex for its models: `codex app-server`, `initialize`, then
    /// `model/list`, then the process is ended — no thread is started.
    /// Calls `done` when the list changed.
    public static func refreshModels(then done: @escaping @Sendable () -> Void) {
        guard let executable = ToolPath.resolve("codex") else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["app-server"]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            p.environment = ToolPath.environment()
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            for line in [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"visor","version":"1"}}}"#,
                #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}"#,
            ] { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
            var buffer = Data()
            var answer: [String: Any]?
            while answer == nil {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["id"] as? Int == 2, let result = object["result"] as? [String: Any] else { continue }
                    answer = result
                    break
                }
            }
            try? input.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
            guard let list = answer?["data"] as? [[String: Any]] else { return }
            let parsed = parse(models: list)
            guard !parsed.models.isEmpty else { return }
            let changed = asked.value.map { $0.models != parsed.models || $0.defaultModel != parsed.defaultModel } ?? true
            asked.value = parsed
            if changed { done() }
        }
    }

    /// `model/list`'s entries as the catalog's: the visible ones, named
    /// codename first ("Astra 6"), their efforts, and which is default.
    static func parse(models list: [[String: Any]]) -> (models: [AgentModel], defaultModel: String?) {
        var models: [AgentModel] = []
        var defaultModel: String?
        for entry in list where entry["hidden"] as? Bool != true {
            guard let id = (entry["model"] as? String) ?? (entry["id"] as? String) else { continue }
            let efforts = ((entry["supportedReasoningEfforts"] as? [[String: Any]]) ?? []).compactMap { $0["reasoningEffort"] as? String }
            let title = (entry["displayName"] as? String).map(Self.title) ?? AgentCatalog.prettyModelName(id)
            models.append(AgentModel(id: id, title: title, subtitle: entry["description"] as? String,
                                     efforts: efforts, defaultEffort: entry["defaultReasoningEffort"] as? String))
            if entry["isDefault"] as? Bool == true { defaultModel = id }
        }
        return (models, defaultModel)
    }

    /// "GPT-6-Astra" → "Astra 6", "GPT-5.6-Sol" → "Sol 5.6", "GPT-5.5" →
    /// "GPT-5.5": the codename first, like Claude's "Fable 5.1".
    static func title(_ display: String) -> String {
        guard display.hasPrefix("GPT-") else { return display }
        let parts = display.dropFirst(4).split(separator: "-").map(String.init)
        let names = parts.filter { !$0.allSatisfy { $0.isNumber || $0 == "." } }
        let versions = parts.filter { $0.allSatisfy { $0.isNumber || $0 == "." } }
        guard !names.isEmpty else { return display }
        return (names + versions).joined(separator: " ")
    }

    /// The models Codex lists in its cache (the listed ones), with the
    /// default from its config; a single default model when the cache is
    /// empty.
    static func catalog() -> AgentCatalog {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var models: [AgentModel] = []
        if let data = try? Data(contentsOf: home.appendingPathComponent(".codex/models_cache.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = (object["models"] as? [[String: Any]]) ?? (object as? [[String: Any]]) {
            for entry in list where (entry["visibility"] as? String ?? "list") == "list" {
                guard let slug = entry["slug"] as? String else { continue }
                let efforts = ((entry["supported_reasoning_levels"] as? [[String: Any]]) ?? []).compactMap { $0["effort"] as? String }
                let title = (entry["display_name"] as? String).map(Self.title) ?? AgentCatalog.prettyModelName(slug)
                models.append(AgentModel(id: slug, title: title, subtitle: entry["description"] as? String,
                                         efforts: efforts, defaultEffort: entry["default_reasoning_level"] as? String))
            }
        }
        var defaultModel: String?
        if let config = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
            for line in config.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("model ="), let quote = trimmed.firstIndex(of: "\"") {
                    defaultModel = String(trimmed[trimmed.index(after: quote)...]).replacingOccurrences(of: "\"", with: "")
                    break
                }
            }
        }
        if models.isEmpty, let defaultModel {
            models = [AgentModel(id: defaultModel, title: AgentCatalog.prettyModelName(defaultModel), efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium")]
        }
        return AgentCatalog(agent: .codex, models: models, defaultModel: defaultModel)
    }
}

/// OpenRouter through the `openrouter` CLI (github.com/AttilaTheFun/
/// open_router_cli), which speaks Claude Code's stream-json protocol: it
/// is driven exactly as Claude is, resumed by its own session id, its
/// sessions kept in ~/.openrouter/sessions. Its key and default model are
/// its own business (`openrouter auth login`), like Claude's and Codex's
/// logins; Visor only runs it.
public final class OpenRouterBackend: AgentBackend, @unchecked Sendable {
    public let kind: AgentKind = .openrouter
    public let tool = "openrouter"

    public init() {}

    public func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess {
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
        guard let cached = Self.cachedModels(), !cached.isEmpty else {
            return AgentCatalog(agent: kind, models: Self.fallback, defaultModel: configured ?? Self.cliDefault, available: available)
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
        return AgentCatalog(agent: kind, models: models, defaultModel: runs, available: available)
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

    /// Fetches the list through the CLI when it is missing or a day old,
    /// then says so; Visor never calls OpenRouter itself.
    public static func refreshIfStale(then done: @escaping @Sendable () -> Void) {
        let file = SessionCatalog.openrouterRoot.appendingPathComponent("models.json")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        guard age == nil || age! > 24 * 60 * 60, let tool = ToolPath.resolve("openrouter") else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["models", "--refresh"]
            p.environment = ToolPath.environment()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            if p.terminationStatus == 0 { done() }
        }
    }
}

/// A value behind a lock, for what a background refresh writes and a
/// catalog reads.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

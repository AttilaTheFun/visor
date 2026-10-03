import Foundation
import Synchronization
import VisorProtocol

/// Codex through its app-server: one long-lived daemon per session, a
/// thread started or resumed by id, each message a turn, a turn
/// interrupted in place. (`CodexProcess`, one `codex exec` per turn, is
/// kept in the tree as the older driver but is not what this makes.)
public final class CodexHarness: AgentHarness {
    public let kind: AgentKind = .codex
    public let tool = "codex"

    public init() {}

    @MainActor public func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess {
        CodexAppServerProcess(cwd: cwd, skipPermissions: skipPermissions, resume: resume)
    }

    /// Codex's own list, as its app-server answered `model/list`; its
    /// models cache on disk until then (and where it has no answer).
    public func catalog() -> AgentCatalog {
        var catalog = Self.catalog()
        if let asked = Self.asked.withLock({ $0 }), !asked.models.isEmpty {
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
    static let asked = Mutex<ModelList?>(nil)

    /// Asks Codex for its models: `codex app-server`, `initialize`, then
    /// `model/list`, then the process is ended — no thread is started.
    public static func refreshModels() async -> ModelRefresh {
        guard let executable = ToolPath.resolve("codex") else { return .unchanged }
        let parsed = await Command.ask(executable, ["app-server"], saying: [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"visor","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}"#,
        ], environment: ToolPath.environment()) { line -> ModelList? in
            guard let object = JSON.object(line), object["id"] as? Int == 2, let result = object["result"] as? [String: Any] else { return nil }
            return parse(models: result["data"] as? [[String: Any]] ?? [])
        }
        guard let parsed, !parsed.models.isEmpty else { return .unchanged }
        return asked.withLock { asked in
            let changed = asked != parsed
            asked = parsed
            return changed ? .changed : .unchanged
        }
    }

    /// `model/list`'s entries as the catalog's: the visible ones, named
    /// codename first ("Astra 6"), their efforts, and which is default.
    static func parse(models list: [[String: Any]]) -> ModelList {
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
        return ModelList(models: models, defaultModel: defaultModel)
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
           let object = try? JSONSerialization.jsonObject(with: data),
           let list = ((object as? [String: Any])?["models"] as? [[String: Any]]) ?? (object as? [[String: Any]]) {
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

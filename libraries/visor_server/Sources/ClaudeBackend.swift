import Foundation
import Synchronization
import VisorProtocol

/// Claude Code, and anything that speaks its stream-json protocol under
/// another tool name (Ori).
public final class ClaudeBackend: AgentBackend {
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
        if tool == "claude", let asked = Self.asked.withLock({ $0.taken }) {
            return AgentCatalog(agent: kind, models: asked.models, defaultModel: Self.configuredModel() ?? asked.defaultModel,
                                available: available)
        }
        return AgentCatalog(agent: kind, models: models, defaultModel: Self.configuredModel(), available: available)
    }

    /// What Claude Code said of its models: the list taken, and a shorter
    /// one it has said once and not yet twice.
    struct Asked: Sendable {
        var taken: ModelList?
        var doubted: [AgentModel]?
    }
    static let asked = Mutex(Asked())

    /// Whether a new list may replace the one held at once: when it keeps
    /// every model the old one had (it may add some), or there was no old
    /// one. A list that drops models waits to be confirmed.
    static func accepts(_ new: [AgentModel], over old: [AgentModel]?) -> Bool {
        guard let old else { return true }
        let ids = Set(new.map(\.id))
        return old.allSatisfy { ids.contains($0.id) }
    }

    /// Asks Claude Code for its models: `claude -p` with stream-json, the
    /// SDK's `initialize` control request, the answer's `models`, then
    /// the process is ended — no turn is run.
    ///
    /// Claude Code's answer is not always the whole list: while the
    /// account's access is in doubt (an organization setting briefly
    /// refusing, say) it offers the base models alone, and the server
    /// once kept that for hours. A list that loses models is not taken at
    /// once: it is `doubted`, to be asked again soon, and taken if it
    /// still says so.
    public static func refreshModels() async -> ModelRefresh {
        guard let executable = ToolPath.resolve("claude") else { return .unchanged }
        let request = #"{"type":"control_request","request_id":"visor-models","request":{"subtype":"initialize"}}"#
        let parsed = await Command.ask(executable, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
                                       saying: [request], environment: ToolPath.environment()) { line -> ModelList? in
            guard let object = JSON.object(line), object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any],
                  let list = ((response["response"] as? [String: Any]) ?? response)["models"] as? [[String: Any]] else { return nil }
            // The answer, whatever it holds: an empty list ends the asking too.
            return parse(models: list) ?? ModelList(models: [], defaultModel: nil)
        }
        guard let parsed, !parsed.models.isEmpty else { return .unchanged }
        return asked.withLock { asked in
            if !accepts(parsed.models, over: asked.taken?.models), asked.doubted != parsed.models {
                asked.doubted = parsed.models
                return .doubted
            }
            asked.doubted = nil
            let changed = asked.taken != parsed
            asked.taken = parsed
            return changed ? .changed : .unchanged
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
    static func parse(models list: [[String: Any]]) -> ModelList? {
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
        return ModelList(models: models, defaultModel: defaultModel)
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

    @MainActor public func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess {
        ClaudeProcess(cwd: cwd, skipPermissions: skipPermissions, resume: resume, tool: tool)
    }
}

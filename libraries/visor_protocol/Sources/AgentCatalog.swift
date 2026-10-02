#if canImport(Foundation)
import Foundation
#endif

/// A provider's models and its default, sent with `welcome`.
public struct AgentCatalog: Codable, Hashable, Sendable {
    public var agent: AgentKind
    public var models: [AgentModel]
    public var defaultModel: String?
    /// The tool is installed on the host.
    public var available: Bool
    /// Something to tell whoever picks a model: that the tool is not
    /// logged in on this computer, say.
    public var note: String?

    public init(agent: AgentKind, models: [AgentModel], defaultModel: String? = nil, available: Bool = true, note: String? = nil) {
        self.agent = agent
        self.models = models
        self.defaultModel = defaultModel
        self.available = available
        self.note = note
    }

    /// The model a session runs: its own, else the provider's default.
    public func model(matching id: String?) -> AgentModel? {
        let wanted = id ?? defaultModel
        if let wanted, let exact = models.first(where: { $0.id == wanted }) { return exact }
        // Claude reports the full name ("claude-fable-5-1") for an alias ("fable").
        if let wanted, let byPrefix = models.first(where: { wanted.contains($0.id) }) { return byPrefix }
        // And its list names some by alias with a context mark ("opus[1m]",
        // "claude-fable-5-1[1m]"), which a reported or older name reaches
        // without the mark. Not for provider/model ids, where a name inside
        // another is a different model.
        if let wanted, !wanted.contains("/") {
            func bare(_ id: String) -> String { id.split(separator: "[").first.map(String.init) ?? id }
            let plain = bare(wanted)
            if let loose = models.first(where: { plain.contains(bare($0.id)) || bare($0.id).contains(plain) }) { return loose }
        }
        return nil
    }

    /// A model id as a name: the catalog's title, or the id tidied up
    /// ("claude-haiku-4-5-20251001" → "Haiku 4.5").
    /// The model a turn ran on instead of the one chosen (nil: the
    /// default), when the agent fell back (a model busy or rate-limited);
    /// nil when it ran on the chosen one, or either is unknown here.
    public func fallback(from chosen: String?, to reported: String?) -> AgentModel? {
        guard let reported, let ran = model(matching: reported), let wanted = model(matching: chosen) else { return nil }
        return ran.id == wanted.id ? nil : ran
    }

    public func title(for id: String?) -> String? {
        if let model = model(matching: id) { return model.title }
        guard let id else { return nil }
        return AgentCatalog.prettyModelName(id)
    }

    public static func prettyModelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        var name: [String] = []
        var version: [String] = []
        for part in parts {
            if part == "claude" || part == "gpt" { continue }
            if part.allSatisfy(\.isNumber) {
                if part.count <= 2 { version.append(part) }
            } else {
                name.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        let head = name.joined(separator: " ")
        return version.isEmpty ? head : head + " " + version.joined(separator: ".")
    }

    public static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra high"
        case "ultra": "Ultra"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

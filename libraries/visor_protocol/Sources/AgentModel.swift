#if canImport(Foundation)
import Foundation
#endif

/// One of a provider's models, as the host lists them (Codex: from its
/// models cache; Claude: the CLI's aliases).
public struct AgentModel: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// The effort levels this model takes, in order.
    public var efforts: [String]
    public var defaultEffort: String?
    /// Who makes it ("OpenAI"), for a list grouped by maker.
    public var group: String?
    /// In the short list a picker opens on; false for the long tail,
    /// shown only under All Models.
    public var listed: Bool

    public init(id: String, title: String, subtitle: String? = nil, efforts: [String], defaultEffort: String? = nil,
                group: String? = nil, listed: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.group = group
        self.listed = listed
    }
}

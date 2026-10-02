#if canImport(Foundation)
import Foundation
#endif

/// A slash command an agent takes ("/compact"), as it describes it.
public struct SlashCommand: Codable, Hashable, Sendable {
    /// Without the slash: "compact".
    public var name: String
    public var description: String
    /// What goes after it, as the agent hints ("[instructions]"), if anything.
    public var argumentHint: String

    public init(name: String, description: String = "", argumentHint: String = "") {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
    }
}

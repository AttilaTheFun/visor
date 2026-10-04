#if canImport(Foundation)
import Foundation
#endif

/// What a session has used, as its agent counted it: tokens, and the
/// dollars they cost where the agent prices them.
public struct SessionUsage: Codable, Hashable, Sendable {
    /// Tokens sent to the model, those read from its cache included.
    public var input: Int
    /// Of `input`, the tokens read from the cache (billed at a fraction).
    public var cached: Int
    public var output: Int
    /// Dollars, where the agent prices its turns (Claude Code, the
    /// openrouter CLI). On a subscription it is what the turns would have
    /// cost at API prices, not what was paid.
    public var cost: Double?

    public init(input: Int = 0, cached: Int = 0, output: Int = 0, cost: Double? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.cost = cost
    }
}

#if canImport(Foundation)
import Foundation
#endif

/// What a session has used, as its agent counted it: tokens, and the
/// dollars they cost where the agent prices them.
public struct SessionUsage: Codable, Hashable, Sendable {
    /// Tokens sent to the model, those read from its cache included. 64
    /// bits everywhere: a long session passes the two billion a 32-bit
    /// `Int` (the web's) holds.
    public var input: Int64
    /// Of `input`, the tokens read from the cache (billed at a fraction).
    public var cached: Int64
    public var output: Int64
    /// Dollars, where the agent prices its turns (Claude Code, the
    /// openrouter CLI). On a subscription it is what the turns would have
    /// cost at API prices, not what was paid.
    public var cost: Double?

    public init(input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0, cost: Double? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.cost = cost
    }
}

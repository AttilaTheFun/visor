#if canImport(Foundation)
import Foundation
#endif

/// One allowance an agent's account has, and how much of it is used: a
/// rolling window (five hours, a week), a budget, a balance of credits.
public struct UsageLimit: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, Sendable { case dollars, credits }
    /// What it is, in words: "5-hour", "Weekly", "Key limit", "Credits".
    public var name: String
    /// The share used, 0…1; nil for a balance with no ceiling.
    public var used: Double?
    /// When it starts over, seconds since 1970; nil when it does not.
    public var resets: Double?
    /// What is left, and the most there is, in `unit`; nil for a share
    /// alone.
    public var left: Double?
    public var total: Double?
    public var unit: Unit?

    public init(name: String, used: Double? = nil, resets: Double? = nil, left: Double? = nil, total: Double? = nil, unit: Unit? = nil) {
        self.name = name
        self.used = used
        self.resets = resets
        self.left = left
        self.total = total
        self.unit = unit
    }
}

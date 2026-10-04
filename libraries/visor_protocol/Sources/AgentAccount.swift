#if canImport(Foundation)
import Foundation
#endif

/// How an agent is paid for on this computer, and how near its account's
/// limits it is, as its sessions last said. Sent with the agent's catalog.
public struct AgentAccount: Codable, Hashable, Sendable {
    /// The plan, in words: "Subscription", "ChatGPT Pro", "API key".
    public var plan: String?
    /// Paid for by a plan rather than by the token: a session's cost is
    /// what its turns would have cost at API prices.
    public var subscription: Bool
    /// The windows and budgets, in the order the agent gives them.
    public var limits: [UsageLimit]
    /// When the agent last said, seconds since 1970.
    public var updated: Double

    public init(plan: String? = nil, subscription: Bool = false, limits: [UsageLimit] = [], updated: Double) {
        self.plan = plan
        self.subscription = subscription
        self.limits = limits
        self.updated = updated
    }
}

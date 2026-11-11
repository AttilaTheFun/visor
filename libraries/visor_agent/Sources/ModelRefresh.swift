import Foundation
import Synchronization
import VisorProtocol

/// What asking an agent for its models came to.
public enum ModelRefresh: Sendable {
    /// The list held is different now.
    case changed
    case unchanged
    /// The answer dropped models and was not taken: ask again soon.
    case doubted
}

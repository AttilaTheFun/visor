import Foundation
import Synchronization
import VisorProtocol

/// An agent's models as it lists them, and which is its default.
struct ModelList: Sendable, Equatable {
    var models: [AgentModel]
    var defaultModel: String?
}

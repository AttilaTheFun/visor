import Foundation
import Synchronization
import VisorProtocol

public enum AgentProcessError: LocalizedError {
    case toolMissing(String)
    case spawnFailed(String)
    /// The agent cannot do what was asked of it (a side question of an
    /// agent that takes none), or did not.
    case declined(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let name): "\(name) is not installed on the host (not found on the login shell's PATH)"
        case .spawnFailed(let message): message
        case .declined(let message): message
        }
    }
}

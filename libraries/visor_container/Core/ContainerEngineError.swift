// Why the container engine refused, for a person.

import Foundation

public enum ContainerEngineError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    /// Turned off in Settings.
    case off
    /// This Mac can't run it (why).
    case cannotRun(String)
    /// Its way out failed its check: session starts are refused (what the check said).
    case noEgress(String)
    /// agent-proxy has no relay port.
    case noRelayPort
    /// It isn't running (stopped while asked).
    case notRunning
    /// A process of that id runs already.
    case duplicateProcess(String)

    public var description: String {
        switch self {
        case .off: "The Sessions container is off in Settings."
        case let .cannotRun(why): "The Sessions container can't run here: \(why)"
        case let .noEgress(why): "The Sessions container has no egress, so sessions aren't started in it: \(why)"
        case .noRelayPort: "agent-proxy has no relay port (agentProxy.relayPort), the container's only way out."
        case .notRunning: "The Sessions container isn't running."
        case let .duplicateProcess(id): "A process \(id) runs in the Sessions container already."
        }
    }

    public var errorDescription: String? { description }
}

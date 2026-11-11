// A runner's first word when it dials the server (docs/runners.md, "A
// runner"), said again whenever its capacity changes.

/// A runner saying what it is and what it can take.
public struct RunnerHello: Codable, Hashable, Sendable {
    /// Where its agents run: processes on its computer (Visor.app's own), a
    /// Linux container (Shireworks' container agent runner, in its primary
    /// container), or a macOS VM (Shireworks' macOS VM agent runner, with
    /// Xcode).
    public enum Kind: String, Codable, Hashable, Sendable {
        case native
        case container
        case macosVM = "macos-vm"
    }

    /// The runner protocol's version this side speaks (docs/runners.md, "The
    /// runner protocol").
    public static let protocolVersion = 2

    public var protocolVersion: Int
    public var id: String
    public var name: String
    public var kind: Kind
    /// The agents it can start.
    public var agents: [AgentKind]
    /// How many more agents it can start now.
    public var capacity: Int
    /// How many it is running.
    public var running: Int
    /// What a queue entry may ask of it: `macbook`, `container`, `shireworks`.
    public var labels: [String]

    public init(id: String, name: String, kind: Kind, agents: [AgentKind], capacity: Int, running: Int = 0, labels: [String] = [],
                protocolVersion: Int = Self.protocolVersion) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.name = name
        self.kind = kind
        self.agents = agents
        self.capacity = capacity
        self.running = running
        self.labels = labels
    }
}

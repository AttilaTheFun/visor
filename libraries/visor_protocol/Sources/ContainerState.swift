// The Sessions container's state, as `GET /api/container` says it
// (docs/containers.md): off (turned off in Settings, or this Mac can't run
// it), starting, running (its egress checked), no egress (it runs, but its
// way out through agent-proxy failed its check: session starts are
// refused), or stopped (on, but not running: not yet used, stopped when
// idle or by hand, or its start failed).

public enum ContainerState: String, Equatable, Sendable, CaseIterable {
    case off
    case starting
    case running
    case noEgress = "no-egress"
    case stopped

    /// For a person.
    public var label: String {
        switch self {
        case .off: "Off"
        case .starting: "Starting"
        case .running: "Running"
        case .noEgress: "No egress"
        case .stopped: "Stopped"
        }
    }
}

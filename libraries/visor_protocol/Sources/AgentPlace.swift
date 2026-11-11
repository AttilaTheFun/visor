// Where a wrapped agent runs (docs/runners.md): on a computer itself, or in
// a container. A container's agent skips its permission prompts; a native
// one keeps the session's choice (#341).

/// Where a wrapped agent runs.
public enum AgentPlace: String, Codable, Hashable, Sendable {
    case native
    case container
}

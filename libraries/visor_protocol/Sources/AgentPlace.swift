// Where a wrapped agent runs (docs/runners.md): on a computer itself, in a
// Linux container, or in a macOS VM. A container's or a VM's agent skips its
// permission prompts; a native one keeps the session's choice (#341).

/// Where a wrapped agent runs.
public enum AgentPlace: String, Codable, Hashable, Sendable {
    case native
    case container
    /// A macOS VM (Shireworks' primary macOS VM), as boxed in as a container.
    case macosVM = "macos-vm"
}

import VisorProtocol
import VisorServices

/// The backends this build knows. Tailscale is the one shipped; a fork
/// registers its own at launch, before the store is made.
@MainActor
public enum Backends {
    private static var registry: [any Backend] = [TailscaleBackend()]

    public static var all: [any Backend] { registry }

    public static func register(_ backend: any Backend) {
        registry.removeAll { $0.id == backend.id }
        registry.append(backend)
    }

    public static func backend(for id: String) -> (any Backend)? {
        registry.first { $0.id == id }
    }

    /// The transport for a computer; an unknown backend gets the first.
    static func transport(for config: HostConfig) -> any HostTransport {
        (backend(for: config.backend) ?? registry[0]).makeTransport()
    }
}

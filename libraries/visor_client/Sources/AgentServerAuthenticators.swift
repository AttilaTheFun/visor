/// The authenticators this build knows: none and the password shipped;
/// a fork registers its own at launch, before the store is made. The
/// password is the default: what a record from before authenticators,
/// or one naming an authenticator this build lacks, gets.
@MainActor
public enum AgentServerAuthenticators {
    private static var registry: [any AgentServerAuthenticator] = [PasswordAuthenticator(), NoAuthenticator()]

    public static var all: [any AgentServerAuthenticator] { registry }

    public static func register(_ authenticator: any AgentServerAuthenticator) {
        registry.removeAll { $0.id == authenticator.id }
        registry.append(authenticator)
    }

    /// The authenticator a record names, or the password.
    public static func authenticator(for record: AgentServerRecord) -> any AgentServerAuthenticator {
        registry.first { $0.id == record.authentication } ?? registry[0]
    }
}

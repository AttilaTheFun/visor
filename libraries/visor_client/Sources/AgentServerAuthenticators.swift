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

    /// What is told of a sign-in: the store, which reconnects the records
    /// that were waiting for it.
    private static var listeners: [@MainActor (String, (AgentServerRecord) -> Bool) -> Void] = []

    static func whenSignedIn(_ listener: @escaping @MainActor (String, (AgentServerRecord) -> Bool) -> Void) {
        listeners.append(listener)
    }

    /// An authenticator signed in once for many records (one SSO session
    /// for every server behind a front, its token kept by the
    /// authenticator): every record that signs in by it, and that
    /// `serving` takes, and that waits for a sign-in is connected again —
    /// with nothing to save in each one's settings.
    public static func signedIn(_ authenticatorID: String, serving: (AgentServerRecord) -> Bool = { _ in true }) {
        for listener in listeners { listener(authenticatorID, serving) }
    }
}

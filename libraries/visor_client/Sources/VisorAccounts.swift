/// The app's account, if a fork has one (`VisorAccount`), and how the
/// store hears that it changed.
@MainActor
public enum VisorAccounts {
    /// The account, set by a fork at launch, before the store is made; nil
    /// for none (the app as it always was).
    public static var current: (any VisorAccount)?

    /// The authenticator the account's servers are signed in to by.
    public static let authenticatorID = "account"

    /// What is told when the account says it changed: the store.
    private static var listeners: [@MainActor () -> Void] = []

    static func whenChanged(_ listener: @escaping @MainActor () -> Void) {
        listeners.append(listener)
    }

    /// The account signed in or out on its own (a session that ran out,
    /// one renewed in the background): the app follows — the servers
    /// listed again, or taken away.
    public static func changed() {
        for listener in listeners { listener() }
    }
}

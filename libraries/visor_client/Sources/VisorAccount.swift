/// A fork's sign-in for the whole app: a company's single sign-on (Okta,
/// say) whose one session reaches several Visor servers behind the
/// company's front. While no one is signed in, the app shows its sign-in
/// in place of the computers; signing in adds the servers the account
/// reaches, and every request to them carries the account's headers;
/// signing out takes them away again.
///
/// None by default: the app is then as it always was. A fork sets one at
/// launch, before the store is made (`VisorAccounts.current`).
@MainActor
public protocol VisorAccount: AnyObject {
    /// What its sign-in is called on the button ("Okta").
    var title: String { get }
    /// Whether someone is signed in now (a session kept from before
    /// counts).
    var isSignedIn: Bool { get }
    /// Signs in — a web sign-in, a device code, whatever the account
    /// needs; throws when it did not happen (the user cancelled).
    func signIn() async throws
    /// Signs out, forgetting the session.
    func signOut()
    /// The servers the signed-in account reaches, as records: each one's
    /// address behind the front, name and id. The store marks them as the
    /// account's and signs in to them by it.
    func servers() async throws -> [AgentServerRecord]
    /// The headers every request to one of its servers carries (a bearer
    /// token, the front's cookie). Throws
    /// `AgentServerError.needsAuthentication` when the session has run out.
    func headers(for record: AgentServerRecord) async throws -> [String: String]
}

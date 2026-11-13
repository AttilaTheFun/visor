import Foundation
import Observation
import VisorProtocol
import VisorServices

/// A MultiPass the person signed in to (MultiPass's docs/front-door.md; the
/// Runner's account before it, docs/runner-accounts.md): its URL, who
/// signed in, and a session of MultiPass's own, kept with the device's
/// secrets. Signed in by a password, a pairing code or GitHub; then every
/// Visor server MultiPass lists is a computer of this account, reached
/// through it at `<url>/multipass/v1/servers/<id>` with the session as its
/// bearer, and not added or forgotten on its own; signed out, they go.
@MainActor
@Observable
public final class RunnerAccount: VisorAccount, Identifiable {
    /// What is kept of it, but its session (a secret of its own).
    public struct Kept: Equatable, Sendable {
        public var id: String
        public var url: String
        public var username: String
        /// The certificate's SHA-256 the person confirmed at the first
        /// sign-in (a Runner's own, on the LAN), nil for one trusted as any
        /// website's (the tailnet's).
        public var fingerprint: String?
        /// When its session ends, in seconds since 1970.
        public var expires: Double?

        var json: JSONValue {
            var fields: [String: JSONValue] = ["id": .string(id), "url": .string(url), "username": .string(username)]
            if let fingerprint { fields["fingerprint"] = .string(fingerprint) }
            if let expires { fields["expires"] = .number(expires) }
            return .object(fields)
        }

        init?(json: JSONValue) {
            guard let id = json["id"].string, let url = json["url"].string, let username = json["username"].string else { return nil }
            self.init(id: id, url: url, username: username, fingerprint: json["fingerprint"].string, expires: json["expires"].double)
        }

        init(id: String, url: String, username: String, fingerprint: String?, expires: Double?) {
            self.id = id
            self.url = url
            self.username = username
            self.fingerprint = fingerprint
            self.expires = expires
        }
    }

    public private(set) var kept: Kept
    /// Its id, which never changes: held apart from `kept`, so it is read
    /// from anywhere (`Identifiable`).
    public let id: String
    public var url: String { kept.url }

    /// Its session, as the secrets keep it: held here too, so the views
    /// see it come and go.
    private var token: String

    init(kept: Kept) {
        self.kept = kept
        id = kept.id
        token = VisorHost.settings?.secret(key: Self.secretKey(kept.id)) ?? ""
    }

    /// The fixture's: its session held, and nothing of the device's read.
    init(fixture kept: Kept, session: String) {
        self.kept = kept
        id = kept.id
        token = session
    }

    /// MultiPass's side for clients.
    static let api = "/multipass/v1"

    /// Where the session is kept with the device's secrets.
    var secretKey: String { Self.secretKey(kept.id) }
    static func secretKey(_ id: String) -> String { "runner-session." + id }

    private func keep(session: String) {
        token = session
        VisorHost.settings?.setSecret(key: secretKey, value: session)
    }

    /// "logan on mini.tail.ts.net".
    public var title: String { "\(kept.username) on \(Self.host(of: kept.url))" }

    public var isSignedIn: Bool {
        !token.isEmpty && (kept.expires ?? .infinity) > Date().timeIntervalSince1970
    }

    /// The name signed in with.
    public var username: String { kept.username }

    /// When its session ends, where MultiPass said.
    public var expires: Date? { kept.expires.map(Date.init(timeIntervalSince1970:)) }

    /// MultiPass asks who it is: the views do, and call `signIn(password:)`,
    /// `signIn(pairing:)` or the GitHub sign-in.
    public func signIn() async throws {
        throw AgentServerError.needsAuthentication
    }

    /// Signs in with the account's name and this password: its session
    /// kept, or what went wrong thrown.
    public func signIn(password: String) async throws {
        try await signIn(proof: .object(["kind": .string("password"), "username": .string(kept.username), "password": .string(password)]),
                         refused: "That name and password don't sign in to this MultiPass.")
    }

    /// Signs in with a pairing code's secret, as the computer's owner.
    public func signIn(pairing secret: String) async throws {
        try await signIn(proof: .object(["kind": .string("pairing"), "secret": .string(secret), "device": .string(VisorHost.deviceName)]),
                         refused: "That pairing code is used up or has run out: make another (multipass-agent pair).")
    }

    /// A sign-in with GitHub begun: the code the person enters at GitHub's
    /// page, the page, and how MultiPass knows it (`poll`).
    public struct GitHubSignIn: Equatable, Sendable {
        public var userCode: String
        public var verificationURI: String
        public var poll: String
        public var interval: Int
    }

    /// Begins signing in with GitHub, which MultiPass asks.
    public func startGitHubSignIn() async throws -> GitHubSignIn {
        guard let http = VisorHost.http else { throw AgentServerError.message("No HTTP service on this host") }
        let text = try await http.request(method: "POST", url: kept.url + Self.api + "/sign-in/github/device", body: "{}", headers: [:])
        guard let answer = parseJSON(text), let code = answer["user_code"].string, let uri = answer["verification_uri"].string,
              let poll = answer["poll"].string else {
            throw AgentServerError.message(parseJSON(text)?["error"].string ?? "MultiPass didn't begin a GitHub sign-in.")
        }
        return GitHubSignIn(userCode: code, verificationURI: uri, poll: poll, interval: max(1, Int(answer["interval"].double ?? 5)))
    }

    /// Whether the person has signed in at GitHub yet: true once they have
    /// (the session kept, the login as the account's name), false while
    /// GitHub waits; thrown when they can't.
    public func finishGitHubSignIn(_ started: GitHubSignIn) async throws -> Bool {
        guard let http = VisorHost.http else { throw AgentServerError.message("No HTTP service on this host") }
        let body = JSONValue.object(["poll": .string(started.poll), "device": .string(VisorHost.deviceName)]).encoded()
        let text: String
        do {
            text = try await http.request(method: "POST", url: kept.url + Self.api + "/sign-in/github/device/poll", body: body, headers: [:])
        } catch {
            if http.status(of: error) == 401 { throw AgentServerError.message("GitHub signed you in, but this MultiPass doesn't let that account in.") }
            throw error
        }
        guard let answer = parseJSON(text) else { return false }
        if answer["status"].string == "pending" { return false }
        try take(answer)
        return true
    }

    /// A sign-in's proof sent; its session kept, or `refused` thrown.
    private func signIn(proof: JSONValue, refused: String) async throws {
        guard let http = VisorHost.http else { throw AgentServerError.message("No HTTP service on this host") }
        let text: String
        do {
            text = try await http.request(method: "POST", url: kept.url + Self.api + "/sign-in", body: proof.encoded(), headers: [:])
        } catch {
            if http.status(of: error) == 401 { throw AgentServerError.message(refused) }
            throw error
        }
        guard let answer = parseJSON(text) else { throw AgentServerError.message("MultiPass didn't give a session.") }
        try take(answer)
    }

    /// A sign-in's answer: its session kept, and who it is for.
    private func take(_ answer: JSONValue) throws {
        guard let session = answer["token"].string, !session.isEmpty else { throw AgentServerError.message("MultiPass didn't give a session.") }
        keep(session: session)
        kept.expires = answer["expires"].double
        if let account = answer["account"].string, !account.isEmpty { kept.username = account }
        RunnerAccounts.save()
    }

    public func signOut() {
        let session = token
        keep(session: "")
        kept.expires = nil
        RunnerAccounts.save()
        guard !session.isEmpty, let http = VisorHost.http else { return }
        let url = kept.url + Self.api + "/sign-out"
        Task { _ = try? await http.request(method: "POST", url: url, body: "{}", headers: ["Authorization": "Bearer " + session]) }
    }

    public func servers() async throws -> [AgentServerRecord] {
        guard let http = VisorHost.http else { throw AgentServerError.message("No HTTP service on this host") }
        let text: String
        do {
            text = try await http.request(method: "GET", url: kept.url + Self.api + "/servers", body: "", headers: try headers())
        } catch {
            if http.status(of: error) == 401 {
                keep(session: "")
                throw AgentServerError.needsAuthentication
            }
            throw error
        }
        return (parseJSON(text)?["servers"].array ?? []).compactMap { server in
            // Visor's own: MultiPass fronts others too (Shireworks').
            guard let id = server["id"].string, !id.isEmpty, Self.isVisor(kind: server["kind"].string) else { return nil }
            var record = AgentServerRecord(name: server["name"].string ?? id, address: kept.url + Self.api + "/servers/" + VisorAgentServer.escape(id),
                                           renamed: true, authentication: RunnerAuthenticator.name, fromAccount: true)
            record.account = kept.id
            return record
        }
    }

    public func headers(for record: AgentServerRecord) async throws -> [String: String] {
        try headers()
    }

    private func headers() throws -> [String: String] {
        guard isSignedIn else { throw AgentServerError.needsAuthentication }
        return ["Authorization": "Bearer " + token]
    }

    /// Whether a server MultiPass lists is a Visor server: `visor`, or the
    /// Runner's places for one (`mac`, `container`).
    static func isVisor(kind: String?) -> Bool {
        guard let kind else { return true }
        return ["visor", "mac", "container"].contains(kind)
    }

    /// A URL's host: what an account is named by.
    static func host(of url: String) -> String {
        var rest = Substring(url)
        if let scheme = rest.firstRange(of: "://") { rest = rest[scheme.upperBound...] }
        let end = rest.firstIndex(where: { $0 == "/" || $0 == ":" }) ?? rest.endIndex
        return String(rest[..<end])
    }
}

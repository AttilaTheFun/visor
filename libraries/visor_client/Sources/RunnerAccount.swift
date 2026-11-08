import Foundation
import Observation
import VisorProtocol
import VisorServices

/// A Visor Runner the person signed in to (docs/runner-accounts.md, step 5):
/// its URL, the name signed in with, and a session of the Runner's own,
/// kept with the device's secrets. Signed in, every server the Runner lists
/// is a computer of this account, reached through the Runner at
/// `<url>/runner/v1/servers/<id>` with the session as its bearer, and not
/// added or forgotten on its own; signed out, they go.
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

    /// When its session ends, where the Runner said.
    public var expires: Date? { kept.expires.map(Date.init(timeIntervalSince1970:)) }

    /// A Runner asks for its password: the views do, and call
    /// `signIn(password:)`.
    public func signIn() async throws {
        throw AgentServerError.needsAuthentication
    }

    /// Signs in with the account's name and this password: its session
    /// kept, or what went wrong thrown.
    public func signIn(password: String) async throws {
        guard let http = VisorHost.http else { throw AgentServerError.message("No HTTP service on this host") }
        let body = JSONValue.object(["kind": .string("password"), "username": .string(kept.username), "password": .string(password)]).encoded()
        let text: String
        do {
            text = try await http.request(method: "POST", url: kept.url + "/runner/v1/sign-in", body: body, headers: [:])
        } catch {
            if http.status(of: error) == 401 { throw AgentServerError.message("That name and password don't sign in to this Runner.") }
            throw error
        }
        guard let answer = parseJSON(text), let session = answer["token"].string, !session.isEmpty else {
            throw AgentServerError.message("The Runner didn't give a session.")
        }
        keep(session: session)
        kept.expires = answer["expires"].double
        RunnerAccounts.save()
    }

    public func signOut() {
        let session = token
        keep(session: "")
        kept.expires = nil
        RunnerAccounts.save()
        guard !session.isEmpty, let http = VisorHost.http else { return }
        let url = kept.url + "/runner/v1/sign-out"
        Task { _ = try? await http.request(method: "POST", url: url, body: "{}", headers: ["Authorization": "Bearer " + session]) }
    }

    public func servers() async throws -> [AgentServerRecord] {
        guard let http = VisorHost.http else { throw AgentServerError.message("No HTTP service on this host") }
        let text: String
        do {
            text = try await http.request(method: "GET", url: kept.url + "/runner/v1/servers", body: "", headers: try headers())
        } catch {
            if http.status(of: error) == 401 {
                keep(session: "")
                throw AgentServerError.needsAuthentication
            }
            throw error
        }
        return (parseJSON(text)?["servers"].array ?? []).compactMap { server in
            guard let id = server["id"].string, !id.isEmpty else { return nil }
            var record = AgentServerRecord(name: server["name"].string ?? id, address: kept.url + "/runner/v1/servers/" + VisorAgentServer.escape(id),
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

    /// A URL's host: what an account is named by.
    static func host(of url: String) -> String {
        var rest = Substring(url)
        if let scheme = rest.firstRange(of: "://") { rest = rest[scheme.upperBound...] }
        let end = rest.firstIndex(where: { $0 == "/" || $0 == ":" }) ?? rest.endIndex
        return String(rest[..<end])
    }
}

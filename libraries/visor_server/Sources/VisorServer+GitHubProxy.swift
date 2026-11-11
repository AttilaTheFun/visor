// The GitHub proxy (`ServerSettings.githubProxy`, docs/github-proxy.md): the
// Runner's, which agents reach GitHub through holding no token of their own.
// Set over REST with the server's password, never an agent's token
// (`GET`/`PUT /api/github-proxy`), as the push proxy is. For each session it
// is on for (`githubProxySessions`), an agent this computer runs is started
// with HTTPS_PROXY naming its server's token, the session and the session's
// repository, a placeholder GH_TOKEN, and the proxy's authority trusted
// beside the system's own (the system's store itself is never changed).

import Foundation
import VisorProtocol

extension VisorServer {
    /// Where the proxy's token for this server is kept with its secrets.
    static let githubProxyTokenKey = "github.proxyToken"
    /// What an agent's gh is given for a token: the proxy puts the session's
    /// in its place.
    static let githubPlaceholderToken = "visor-github-proxy"

    /// The proxy's authority, as the Runner gave it.
    static var githubProxyAuthorityURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("github-proxy-ca.pem", isDirectory: false)
    }

    /// Its authority and the system's, one file for the tools that read one.
    static var githubProxyBundleURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("github-proxy-bundle.pem", isDirectory: false)
    }

    /// `GET /api/github-proxy`: its address, the sessions it is on for, and
    /// whether a token and an authority are kept (never the token).
    func restGitHubProxy(_ call: RESTCall) -> HTTPResponse {
        let kept = !(Self.secrets.get(Self.githubProxyTokenKey) ?? "").isEmpty
        let authority = FileManager.default.fileExists(atPath: Self.githubProxyAuthorityURL.path)
        return .json(JSONValue.object(["url": .string(settings.githubProxy), "sessions": .array(settings.githubProxySessions.map(JSONValue.string)),
                                       "kept": .bool(kept), "authority": .bool(authority)]).encoded())
    }

    /// `PUT /api/github-proxy {url, token?, authority?, sessions?}`: the
    /// proxy, or none (an empty url, which forgets the token too). The
    /// authority is its PEM certificate; the sessions are ids, or `*`. Not
    /// with an agent's token: an agent that could move the proxy could read
    /// every other session's traffic to GitHub.
    func restSetGitHubProxy(_ call: RESTCall) -> HTTPResponse {
        if !call.request.trusted, call.request.authorization == agentToken {
            return HTTPResponse(403, Envelope.error("An agent can't set this computer's GitHub proxy.").encoded())
        }
        guard let body = parseJSON(call.request.body), let url = body["url"].string else {
            return HTTPResponse(400, Envelope.error("Send {\"url\": …, \"token\": …, \"authority\": …, \"sessions\": […]}.").encoded())
        }
        let address = url.trimmingCharacters(in: .whitespaces)
        if address.isEmpty {
            settings.githubProxy = ""
            settings.githubProxySessions = []
            Self.secrets.set(Self.githubProxyTokenKey, nil)
            return restGitHubProxy(call)
        }
        guard let parsed = URLComponents(string: address), parsed.scheme == "http", parsed.host?.isEmpty == false, parsed.port != nil else {
            return HTTPResponse(400, Envelope.error("\(address) is not an http://host:port address.").encoded())
        }
        if let authority = body["authority"].string {
            guard authority.contains("-----BEGIN CERTIFICATE-----") else {
                return HTTPResponse(400, Envelope.error("The authority is a PEM certificate.").encoded())
            }
            try? Data(authority.utf8).write(to: Self.githubProxyAuthorityURL, options: .atomic)
        }
        if let token = body["token"].string, !token.isEmpty { Self.secrets.set(Self.githubProxyTokenKey, token) }
        if let sessions = body["sessions"].array { settings.githubProxySessions = sessions.compactMap(\.string) }
        settings.githubProxy = address
        return restGitHubProxy(call)
    }

    /// What an agent of `info`'s is started with to go to GitHub through the
    /// proxy: nothing when the proxy is off or isn't on for the session.
    func githubProxyEnvironment(for info: SessionInfo) -> [String: String] {
        guard !settings.githubProxy.isEmpty,
              settings.githubProxySessions.contains("*") || settings.githubProxySessions.contains(info.id),
              let token = Self.secrets.get(Self.githubProxyTokenKey), !token.isEmpty,
              var proxy = URLComponents(string: settings.githubProxy),
              let authority = try? String(contentsOf: Self.githubProxyAuthorityURL, encoding: .utf8) else { return [:] }
        let session = info.id + (GitHubRepository.ofCheckout(folder: info.cwd).map { "@" + $0 } ?? "")
        proxy.percentEncodedUser = Self.userInfoEncoded(token)
        proxy.percentEncodedPassword = Self.userInfoEncoded(session)
        guard let url = proxy.string else { return [:] }
        var environment = ["HTTPS_PROXY": url, "https_proxy": url, "NO_PROXY": "localhost,127.0.0.1,::1", "no_proxy": "localhost,127.0.0.1,::1",
                           "GH_TOKEN": Self.githubPlaceholderToken, "NODE_EXTRA_CA_CERTS": Self.githubProxyAuthorityURL.path]
        // The system's authorities and the proxy's, for git, curl and gh.
        let system = ServerPlatform.current.tools.certificateBundle.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let bundle = system + (system.hasSuffix("\n") || system.isEmpty ? "" : "\n") + authority
        if (try? String(contentsOf: Self.githubProxyBundleURL, encoding: .utf8)) != bundle {
            try? Data(bundle.utf8).write(to: Self.githubProxyBundleURL, options: .atomic)
        }
        for name in ["SSL_CERT_FILE", "GIT_SSL_CAINFO", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE"] {
            environment[name] = Self.githubProxyBundleURL.path
        }
        return environment
    }

    /// Text as a URL's user or password part takes it: everything but
    /// letters, digits and `-._~` percent-encoded (the session's `@` and
    /// its repository's `/` included).
    static func userInfoEncoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

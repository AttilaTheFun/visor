// The push proxy (`ServerSettings.pushProxy`): where a computer with no APNs
// key of its own sends its pushes, unsigned, for the proxy to sign with the
// key it alone holds (Visor Runner's, docs/co-tenancy.md: a server in a
// container keeps no key). Set over REST with the server's password, never
// an agent's token (`GET`/`PUT /api/push-proxy`), as the MCP servers are.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Where the proxy's token for this server is kept with its secrets.
    static let pushProxyTokenKey = "push.proxyToken"

    /// The proxy and this server's token for it, when one is set.
    var pushProxy: (url: String, token: String)? {
        guard !settings.pushProxy.isEmpty else { return nil }
        return (settings.pushProxy, Self.secrets.get(Self.pushProxyTokenKey) ?? "")
    }

    /// `GET /api/push-proxy`: its address, and whether a token is kept
    /// (never the token).
    func restPushProxy(_ call: RESTCall) -> HTTPResponse {
        let kept = !(Self.secrets.get(Self.pushProxyTokenKey) ?? "").isEmpty
        return .json(JSONValue.object(["url": .string(settings.pushProxy), "kept": .bool(kept)]).encoded())
    }

    /// `PUT /api/push-proxy {url, token?}`: the proxy, or none (an empty
    /// url, which forgets the token too). A token sent is kept with the
    /// secrets; none sent keeps the one kept. Not with an agent's token: an
    /// agent that could move the proxy could send the pushes anywhere.
    func restSetPushProxy(_ call: RESTCall) -> HTTPResponse {
        if !call.request.trusted, call.request.authorization == agentToken {
            return HTTPResponse(403, Envelope.error("An agent can't set this computer's push proxy.").encoded())
        }
        guard let body = parseJSON(call.request.body), let url = body["url"].string else {
            return HTTPResponse(400, Envelope.error("Send {\"url\": …, \"token\": …}.").encoded())
        }
        let address = url.trimmingCharacters(in: .whitespaces)
        if address.isEmpty {
            settings.pushProxy = ""
            Self.secrets.set(Self.pushProxyTokenKey, nil)
            return restPushProxy(call)
        }
        guard let parsed = URLComponents(string: address), ["http", "https"].contains(parsed.scheme ?? ""), parsed.host?.isEmpty == false else {
            return HTTPResponse(400, Envelope.error("\(address) is not an http(s) address.").encoded())
        }
        if let token = body["token"].string, !token.isEmpty { Self.secrets.set(Self.pushProxyTokenKey, token) }
        settings.pushProxy = address
        return restPushProxy(call)
    }
}

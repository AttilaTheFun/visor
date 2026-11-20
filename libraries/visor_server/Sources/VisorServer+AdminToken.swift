// The admin token over REST (AdminToken), and as the binaries that run the
// server set it up:
//
//   GET  /api/admin-token         {exists, holding: "kept" | "givenAtLaunch"}
//   POST /api/admin-token         {token}: the first one, shown this once,
//                                 only where it is kept and there is none
//                                 (409 otherwise)
//   POST /api/admin-token/rotate  {token}: a new one in place of the one the
//                                 request's bearer presents (403 without
//                                 it), shown this once; the old one stops
//                                 working now
//   POST /api/admin-token/reset   {token}: a new one without the current
//                                 one, shown this once: Visor.app's menu
//                                 alone (its app key on the socket file,
//                                 VisorServer.isOwnApp; 403 otherwise)
//
// Each is an admin route, as every REST route is (authorized): never an
// agent's token. Rotating takes the current token whatever else lets the
// request in (the password, the trusted socket): nothing over REST resets
// it without it but the Mac's menu, Reset Admin Token…, which shows the
// app key the keychain keeps for Visor's processes alone, whether the
// server runs in the app or as its agent (resetAdminToken). Rotating or resetting it also
// ends the `hello` tokens handed out to a request it let in (they never
// expire otherwise): the old token's holder keeps no way in through them.

import Foundation
import VisorProtocol

extension VisorServer {
    /// `/api/admin-token…`, by method.
    func restAdminToken(_ call: RESTCall) -> HTTPResponse {
        switch (call.request.method, call.parts.count) {
        case ("GET", 1):
            return .json(JSONValue.object(["exists": .bool(adminToken.exists), "holding": .string(Self.wire(adminToken.holding))]).encoded())
        case ("POST", 1):
            return answer(adminToken.create(), status: 201, what: "made")
        case ("POST", 2) where call.parts[1] == "rotate":
            return answer(adminToken.rotate(presenting: call.request.authorization), status: 200, what: "rotated")
        case ("POST", 2) where call.parts[1] == "reset":
            guard isOwnApp(call.request) else {
                return HTTPResponse(403, Envelope.error("The admin token is reset from Visor's menu on this Mac, or rotated with the current one.").encoded())
            }
            guard let token = resetAdminToken() else { return HTTPResponse(409, Envelope.error("The admin token is given at launch here").encoded()) }
            return HTTPResponse(200, JSONValue.object(["token": .string(token)]).encoded())
        default:
            return HTTPResponse(404, "{\"error\":\"not found\"}")
        }
    }

    private func answer(_ result: Result<String, AdminToken.Refusal>, status: Int, what: String) -> HTTPResponse {
        switch result {
        case .success(let token):
            Self.log("admin token \(what)")
            forgetAdminHelloTokens()
            return HTTPResponse(status, JSONValue.object(["token": .string(token)]).encoded())
        case .failure(let refusal):
            return HTTPResponse(refusal == .notPresented ? 403 : 409, Envelope.error(refusal.message).encoded())
        }
    }

    private static func wire(_ holding: AdminToken.Holding) -> String {
        switch holding {
        case .kept: "kept"
        case .givenAtLaunch: "givenAtLaunch"
        }
    }

    /// The command-line server's: its admin token as given at launch
    /// (VISOR_ADMIN_TOKEN, `--admin-token-file`), its hash held in memory
    /// alone, never written; or none, said in the log. Signing keys may
    /// then be rotated in an emergency over REST, there being no menu bar.
    public func useAdminTokenGivenAtLaunch(_ token: String?) {
        adminToken = AdminToken(givenAtLaunch: token)
        emergencyRotationOverREST = true
        if adminToken.exists {
            Self.log("admin token: given at launch (its hash held in memory alone)")
        } else {
            Self.log("admin token: none given at launch (VISOR_ADMIN_TOKEN or --admin-token-file): "
                + "admin REST takes only the client password and the local socket")
        }
    }

    /// Whether there is an admin token (Settings, the menu bar).
    public var hasAdminToken: Bool { adminToken.exists }

    /// The first admin token, shown this once; nil when there is one
    /// already, or it is given at launch.
    public func createAdminToken() -> String? {
        guard case .success(let token) = adminToken.create() else { return nil }
        Self.log("admin token made")
        return token
    }

    /// The menu bar's Reset Admin Token…: a new one without the current
    /// one, shown this once. Nil where it is given at launch.
    public func resetAdminToken() -> String? {
        guard let token = adminToken.reset() else { return nil }
        Self.log("admin token reset from the menu bar")
        forgetAdminHelloTokens()
        return token
    }
}

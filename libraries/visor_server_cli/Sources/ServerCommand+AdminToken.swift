// The admin token and the agents' tokens' signing keys, from the command
// line: asked of the server running on this computer over its trusted
// socket (LocalServerCall), the menu bar app's or the command-line one's.
//
//   admin-token              the first admin token, shown once: only where
//                            the server keeps one (the menu bar app) and
//                            none exists yet
//   admin-token rotate       a new one in place of $VISOR_ADMIN_TOKEN, shown
//                            once; the old one stops working at once
//   admin-token generate     a fresh random token, printed and kept nowhere:
//                            for a command-line server's launch
//                            (VISOR_ADMIN_TOKEN, --admin-token-file)
//   keys rotate              a new signing key; the one before kept a day
//   keys rotate --drop-previous
//                            every other key dropped, every agent's token
//                            with it: the command-line server's alone (on a
//                            Mac, Visor Server's menu)
//
// None reads a token from its arguments, and none resets the admin token
// without the current one.

import Foundation
import VisorProtocol
import VisorServer

extension ServerCommand {
    @MainActor
    func adminToken(_ rest: [String]) async throws {
        switch rest.first ?? "create" {
        case "create":
            let answer = try await LocalServerCall(method: "POST", path: "/api/admin-token").send(through: system)
            print(try Self.token(in: answer))
        case "rotate":
            guard let current = ProcessInfo.processInfo.environment["VISOR_ADMIN_TOKEN"], !current.isEmpty else {
                throw CommandLineError.failed("VISOR_ADMIN_TOKEN is unset: rotating the admin token takes the current one from it")
            }
            let answer = try await LocalServerCall(method: "POST", path: "/api/admin-token/rotate", bearer: current).send(through: system)
            print(try Self.token(in: answer))
        case "generate":
            print(SecretToken.mint())
        default:
            throw CommandLineError.usage("admin-token takes nothing, rotate or generate")
        }
    }

    @MainActor
    func keys(_ rest: [String]) async throws {
        guard rest.first == "rotate", rest.count <= 2, rest.count == 1 || rest[1] == "--drop-previous" else {
            throw CommandLineError.usage("keys takes rotate [--drop-previous]")
        }
        let drop = rest.count == 2
        let answer = try await LocalServerCall(method: "POST", path: "/api/keys/rotate", body: "{\"dropPrevious\":\(drop)}").send(through: system)
        guard answer.status == 200, let current = parseJSON(answer.body)?["current"].string else {
            throw CommandLineError.failed(Self.why(answer))
        }
        print(drop ? "Signing keys rotated to \(current), every other key dropped: every agent's token was refused from then on."
                   : "Signing keys rotated to \(current); the one before is kept for a day.")
    }

    /// The token an answer carries, or why there is none.
    static func token(in answer: (status: Int, body: String)) throws -> String {
        guard (200..<300).contains(answer.status), let token = parseJSON(answer.body)?["token"].string, !token.isEmpty else {
            throw CommandLineError.failed(why(answer))
        }
        return token
    }

    /// What a refused answer says.
    static func why(_ answer: (status: Int, body: String)) -> String {
        parseJSON(answer.body)?["error"].string ?? "the server answered \(answer.status)"
    }
}

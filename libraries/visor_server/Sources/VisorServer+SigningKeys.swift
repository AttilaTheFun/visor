// The agents' tokens' signing keys (SigningKeys) rotated: from the menu
// bar (rotateSigningKeys), or over REST by an admin (the command-line
// server's `visor-server keys rotate`, over the trusted socket):
//
//   GET  /api/keys                       {current, kids}: names, never keys
//   POST /api/keys/rotate {dropPrevious?} {current, kids}
//
// A rotation makes a new current key and keeps the one before for a day,
// as long as the tokens it signed last. An emergency one (`dropPrevious`)
// drops every other key, and every session's and runner's agent's token
// with it: over REST only where the server says so (the command-line
// server, emergencyRotationOverREST), from the menu bar alone on a Mac.
// Neither touches the admin token. Either way the native sessions' token
// files are re-minted at once, so their agents carry on; after an
// emergency one, each runner's agent is told to stop and its session carried
// on by a new job with a fresh token (resumeDriven; stopped, where it can't
// be), since its runner's renewals show the token its claim gave it, which
// no longer verifies.

import Foundation
import VisorProtocol

extension VisorServer {
    /// `/api/keys…`, by method.
    func restSigningKeys(_ call: RESTCall) -> HTTPResponse {
        switch (call.request.method, call.parts.count) {
        case ("GET", 1):
            return .json(keysJSON())
        case ("POST", 2) where call.parts[1] == "rotate":
            let dropPrevious = parseJSON(call.request.body)?["dropPrevious"].bool ?? false
            if dropPrevious, !emergencyRotationOverREST {
                return HTTPResponse(403, Envelope.error("An emergency rotation (every other key dropped) is made from Visor Server's "
                    + "menu on this computer, not over REST.").encoded())
            }
            rotateSigningKeys(dropPrevious: dropPrevious)
            return .json(keysJSON())
        default:
            return HTTPResponse(404, "{\"error\":\"not found\"}")
        }
    }

    private func keysJSON() -> String {
        JSONValue.object(["current": .string(agentTokens.keys.currentKID), "kids": .array(agentTokens.keys.kids.map { .string($0) })])
            .encoded()
    }

    /// A new current signing key (the one before kept for a day), or, in
    /// an emergency, every other key dropped and every agent's token with
    /// it. The native sessions' token files are re-minted now; after an
    /// emergency, the runners' agents are carried on by new jobs.
    public func rotateSigningKeys(dropPrevious: Bool) {
        let kid = agentTokens.keys.rotate(dropPrevious: dropPrevious)
        Self.log(dropPrevious ? "signing keys: emergency rotation to \(kid); every other key, and every agent's token, dropped"
                              : "signing keys: rotated to \(kid); the one before is kept for a day")
        refreshSessionTokenFiles()
        guard dropPrevious else { return }
        for record in sessions where record.driven && !record.info.archived {
            // Told to stop now, over its stream: its runner's renewals no
            // longer verify, so its claim's end wouldn't reach it.
            record.process.stop()
            if !resumeDriven(record, why: "restarting, after an emergency rotation of the signing keys, the agent of") {
                stopDriven(record)
            }
        }
    }
}

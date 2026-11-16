// An agent's token as its wrapper (and its runner) shows it on each call:
// gRPC metadata `authorization: Bearer <token>` (agent_protocol's
// Job.token). Only this driver and dispatcher take it: never the server's
// REST or WebSocket side, which know nothing of it.

import Foundation
import GRPCCore

enum AgentBearer {
    /// The token a call's metadata shows, if any.
    static func token(in metadata: Metadata) -> String? {
        for value in metadata[stringValues: "authorization"] {
            let words = value.trimmingCharacters(in: .whitespaces)
            guard words.count > 7, words.prefix(7).lowercased() == "bearer " else { continue }
            let token = words.dropFirst(7).trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { return token }
        }
        return nil
    }

    /// What a call for an agent whose token it doesn't show is refused with.
    static func refusal(_ why: String) -> RPCError {
        RPCError(code: .unauthenticated, message: why)
    }
}

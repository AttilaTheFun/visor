// An agent's token as its wrapper (and its runner) shows it on each call:
// gRPC metadata `authorization: Bearer <token>` (agent_protocol's
// Job.token). Only this driver and dispatcher take it: never the server's
// REST or WebSocket side, which know nothing of it. A runner's own token
// (RunnerTokens) goes the same way: alone on a Claim, and beside its
// agent's on a renewal or a release (a second `authorization` value).

import Foundation
import GRPCCore
import VisorServer

enum AgentBearer {
    /// The token a call's metadata shows, if any.
    static func token(in metadata: Metadata) -> String? {
        tokens(in: metadata).first
    }

    /// Every token a call's metadata shows, in order.
    static func tokens(in metadata: Metadata) -> [String] {
        metadata[stringValues: "authorization"].compactMap { value in
            let words = value.trimmingCharacters(in: .whitespaces)
            guard words.count > 7, words.prefix(7).lowercased() == "bearer " else { return nil }
            let token = words.dropFirst(7).trimmingCharacters(in: .whitespaces)
            return token.isEmpty ? nil : token
        }
    }

    /// What a call refused by a runner token's check is refused with.
    static func refusal(_ admission: RunnerTokens.Admission) -> RPCError? {
        switch admission {
        case .admitted: nil
        case .unauthenticated(let why): RPCError(code: .unauthenticated, message: why)
        case .permissionDenied(let why): RPCError(code: .permissionDenied, message: why)
        }
    }

    /// What a call for an agent whose token it doesn't show is refused with.
    static func refusal(_ why: String) -> RPCError {
        RPCError(code: .unauthenticated, message: why)
    }
}

import Foundation
import VisorProtocol

/// What a session last looked like, for telling what changed.
struct PushState: Equatable {
    var busy = false
    var waiting = false
    var failed = false
    var goal: String?
    var goalSince: Double?

    /// The session's state in a word, as a widget shows it: waiting for
    /// approval, working, working toward a goal, or idle.
    var status: String { waiting ? "waiting" : busy ? "working" : goal != nil ? "goal" : "idle" }
}

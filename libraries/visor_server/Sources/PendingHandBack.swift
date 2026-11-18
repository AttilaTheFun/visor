// A move back waiting for its runner's agent to return its conversation
// (VisorServer+HandBack): what it comes back to if the conversation doesn't
// come, and who waits for it to end.

import Foundation

struct PendingHandBack {
    /// The runner's agent asked to hand back (its move's).
    let agent: String
    /// The conversation it carries on here if none is returned.
    let resume: String
    /// The folder it works in here ("": as it is).
    let cwd: String
    let why: String
    let loud: Bool
    /// Whether its wrapper's ReturnConversation has begun: its files are
    /// coming, so the wait is longer (VisorServer.handBackReceiveWait).
    var receiving = false
    /// What waits for it to end (REST's moveBack).
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// Its wait, cancelled once it ends.
    var timeout: Task<Void, Never>?
}

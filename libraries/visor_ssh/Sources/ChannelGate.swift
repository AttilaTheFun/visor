// How many channels one SSH connection has open at once: under the
// computer's own limit (sshd's MaxSessions, ten unless set), the rest
// waiting their turn. The app's HTTP session opens up to sixteen
// connections to a tunnel's port, each a channel; past sshd's limit the
// channel was refused and the connection here closed with nothing said, a
// request on it lost ("the network connection was lost": every send from
// the MacBook to the Mini for ten minutes, 26 Nov 2026).

/// The channels open, and the connections waiting for one: kept on the
/// connection's event loop alone.
final class ChannelGate {
    /// Below sshd's default MaxSessions (10), with room for a refusal's
    /// retry.
    static let standardLimit = 8

    let limit: Int
    private(set) var open = 0
    private var waiting: [() -> Void] = []

    init(limit: Int = ChannelGate.standardLimit) {
        self.limit = max(1, limit)
    }

    /// The connections waiting for a channel now.
    var queued: Int { waiting.count }

    /// Runs `go` now if there is room, else once there is; each that runs
    /// is let go of by one `leave`.
    func enter(_ go: @escaping () -> Void) {
        guard open < limit else { return waiting.append(go) }
        open += 1
        go()
    }

    /// A channel let go of: the next waiting takes its place.
    func leave() {
        guard !waiting.isEmpty else {
            open = max(0, open - 1)
            return
        }
        waiting.removeFirst()()
    }
}

// How many of containers' streams the relay listener carries at once (NCH's
// review of #414): every stream a thread of its own, and a tunnel, a dial-in
// or a forward two more (Splice), so these caps bound the threads too. Past
// the cap on all of them a new stream is closed unanswered; past one
// lease's, that lease's new request is answered 503. Streams still reading
// the relay's header, named by no lease yet, have a cap of their own, below
// the one on all (NCH's review of #414): past it a new stream is closed
// unanswered, so streams that never say who they are can't hold every
// place, and one lease's cap is below the one on all, so one container
// can't either.

import Foundation

/// Streams counted, in all and by lease.
final class ConnectionCaps: Sendable {
    let total: Int
    let perLease: Int
    let unnamed: Int
    private let counts = Locked<(all: Int, unnamed: Int, byLease: [String: Int])>((0, 0, [:]))
    /// When each refusal was last logged, so a burst logs once.
    private let lastLogged = Locked<[String: Date]>([:])

    init(total: Int, perLease: Int, unnamed: Int = RelayListener.defaultMaxUnnamed) {
        self.total = max(total, 1)
        self.perLease = max(perLease, 1)
        self.unnamed = max(unnamed, 1)
    }

    /// Why these caps would let one lease, or streams that never name one,
    /// hold every place; nil when they don't.
    static func problem(total: Int, perLease: Int, unnamed: Int) -> String? {
        if perLease >= total { return "maxConnectionsPerLease (\(perLease)) must be below maxConnections (\(total)): one container would hold every stream" }
        if unnamed >= total { return "the streams still reading their header (\(unnamed)) must be fewer than maxConnections (\(total))" }
        return nil
    }

    /// Room for one more stream, its header still to read: counted (in all
    /// and as unnamed), or false.
    func admit() -> Bool {
        counts.withLock { counts in
            guard counts.all < total, counts.unnamed < unnamed else { return false }
            counts.all += 1
            counts.unnamed += 1
            return true
        }
    }

    /// Whether the cap on unnamed streams is the one that's full.
    var unnamedFull: Bool { counts.withLock { $0.unnamed >= unnamed } }

    /// A stream's header read (or given up on): no longer unnamed.
    func named() { counts.withLock { $0.unnamed -= 1 } }

    func release() { counts.withLock { $0.all -= 1 } }

    /// Room for one more of `lease`'s: counted, or false.
    func admit(lease: String) -> Bool {
        counts.withLock { counts in
            guard counts.byLease[lease, default: 0] < perLease else { return false }
            counts.byLease[lease, default: 0] += 1
            return true
        }
    }

    func release(lease: String) {
        counts.withLock { counts in
            let left = counts.byLease[lease, default: 1] - 1
            counts.byLease[lease] = left > 0 ? left : nil
        }
    }

    /// Whether a refusal of `kind` should be logged now: once in ten seconds.
    func shouldLog(_ kind: String, now: Date = Date()) -> Bool {
        lastLogged.withLock { last in
            if let then = last[kind], now.timeIntervalSince(then) < 10 { return false }
            last[kind] = now
            return true
        }
    }
}

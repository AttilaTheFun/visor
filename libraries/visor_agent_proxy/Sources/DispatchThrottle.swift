import Foundation

/// How many dispatches on a repository's default branch the gate has let
/// through in the last hour (NCH's conditions for agents' release
/// proposals, 26 Nov 2026): at most gate.json's `mainDispatch.perHour` for
/// each repository, whoever asks. One per gate (GitHubGate's), so every
/// container's agents share it; kept in memory, so a restart starts afresh.
/// A dispatch is counted once its checks have passed, whether or not GitHub
/// then runs it.
public final class DispatchThrottle: Sendable {
    static let window: TimeInterval = 3600

    private let now: @Sendable () -> Date
    /// Each repository's (lower case) dispatches let through, oldest first.
    private let taken = Locked<[String: [Date]]>([:])

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// One more of `repository`'s, if fewer than `limit` went in the last
    /// hour: nil, and it's counted. Else how long until the oldest of them
    /// leaves the hour, and nothing is counted.
    func take(_ repository: String, limit: Int) -> TimeInterval? {
        let now = self.now()
        let key = repository.lowercased()
        return taken.withLock { taken -> TimeInterval? in
            var recent = (taken[key] ?? []).filter { now.timeIntervalSince($0) < Self.window }
            defer { taken[key] = recent }
            guard recent.count < limit else { return recent.first.map { Self.window - now.timeIntervalSince($0) } ?? Self.window }
            recent.append(now)
            return nil
        }
    }
}

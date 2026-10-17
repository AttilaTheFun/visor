// Signing in by several paths at once: the first at once, each next a
// moment after the one before (its head start) unless one has answered (or at once when
// every one before it has failed), and the first to get in taken. A path
// that does not answer — an address left behind, a network the device is
// not on — then costs a moment rather than its whole timeout, and the
// order still says which path gets its head start. Each try keeps its own
// connection (`SignIn`) until it wins; a try that ends after another won
// closes its own.

import VisorProtocol
import VisorServices

extension VisorAgentServer {
    /// One round of tries: which have started, which have failed and why,
    /// the one that got in, and the sign-in waiting on it.
    @MainActor
    final class PathRace {
        let paths: [String]
        var started = 0
        var failed: [Int: Error] = [:]
        var won: SignIn?
        var over = false
        var waiting: CheckedContinuation<Void, Error>?

        init(paths: [String]) { self.paths = paths }

        /// What the round says when nothing got in: the server asking for
        /// credentials if any path heard so, else what the first path met.
        var failure: Error {
            if failed.values.contains(where: { $0 as? AgentServerError == .needsAuthentication }) { return AgentServerError.needsAuthentication }
            return failed[0] ?? failed.values.first ?? AgentServerError.message("No path answered")
        }
    }

    public var racesPaths: Bool { true }

    public func authenticate(_ record: AgentServerRecord, byFirstOf paths: [String], headStarts: [Int32],
                             timeouts: [Int32]) async throws -> (name: String?, path: String) {
        guard paths.count > 1 else {
            var one = record
            one.address = paths.first ?? record.address
            return (try await authenticate(one), one.address)
        }
        let opening = beginSignIn()
        let race = PathRace(paths: paths)
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, Error>) in
            race.waiting = waiting
            start(0, of: race, record, opening: opening, headStarts: headStarts, timeouts: timeouts)
        }
        guard let won = race.won, opening == tunnelOpenings else {
            race.won?.session?.close()
            throw AgentServerError.message("Signing in again")
        }
        return (take(won), won.record.address)
    }

    /// Starts the round's next try, if it is still that one's turn, and
    /// the round is still the server's (a sign-in begun since ends it).
    private func start(_ index: Int, of race: PathRace, _ record: AgentServerRecord, opening: Int, headStarts: [Int32], timeouts: [Int32]) {
        guard !race.over, index < race.paths.count, race.started == index else { return }
        guard opening == tunnelOpenings else { return overtake(race) }
        race.started = index + 1
        var attempt = record
        attempt.address = race.paths[index]
        let log = ConnectionLog.shared
        let subject = record.name.isEmpty ? record.address : record.name
        let began = log.now()
        if index > 0 { log.note(subject, "also signing in by \(attempt.address)") }
        // The next path, if this one has not answered by then.
        if index + 1 < race.paths.count {
            let head = index < headStarts.count ? headStarts[index] : headStarts.last ?? 400
            Task { [weak self] in
                await self?.delay(milliseconds: head)
                self?.start(index + 1, of: race, record, opening: opening, headStarts: headStarts, timeouts: timeouts)
            }
        }
        // Given up on after its time.
        let timeout = index < timeouts.count ? timeouts[index] : timeouts.last ?? 5_000
        Task { [weak self] in
            await self?.delay(milliseconds: timeout)
            self?.lost(index, of: race, AgentServerError.message("No answer to the sign-in by \(attempt.address) in \(timeout) ms"),
                       record, opening: opening, headStarts: headStarts, timeouts: timeouts)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let signIn = try await self.signIn(attempt, opening: opening)
                // Another got in first, or the try was given up on.
                guard !race.over, race.failed[index] == nil else {
                    signIn.session?.close()
                    return
                }
                race.over = true
                race.won = signIn
                log.note(subject, "\(attempt.address) got in first, after \(log.since(began)) ms")
                race.waiting?.resume()
                race.waiting = nil
            } catch {
                self.lost(index, of: race, error, record, opening: opening, headStarts: headStarts, timeouts: timeouts)
            }
        }
    }

    /// A sign-in begun since owns the server: this round ends, starting
    /// nothing more.
    private func overtake(_ race: PathRace) {
        race.over = true
        race.waiting?.resume(throwing: AgentServerError.message("Signing in again"))
        race.waiting = nil
    }

    /// A try failed (or ran out of time): once every path has, the round
    /// does; once every path started so far has, the next starts at once.
    private func lost(_ index: Int, of race: PathRace, _ error: Error, _ record: AgentServerRecord, opening: Int, headStarts: [Int32],
                      timeouts: [Int32]) {
        guard !race.over, race.failed[index] == nil else { return }
        guard opening == tunnelOpenings else { return overtake(race) }
        race.failed[index] = error
        ConnectionLog.shared.note(record.name.isEmpty ? record.address : record.name, "\(race.paths[index]) failed: \(error)")
        if race.failed.count == race.paths.count {
            race.over = true
            race.waiting?.resume(throwing: race.failure)
            race.waiting = nil
            return
        }
        if race.failed.count == race.started { start(race.started, of: race, record, opening: opening, headStarts: headStarts, timeouts: timeouts) }
    }
}

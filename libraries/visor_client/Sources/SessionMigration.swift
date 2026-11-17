// Moving a session from one server to another through this device: the
// session's server offers it (its agent's own files for the conversation:
// its transcript, the folder beside it, Claude's memory), and the other
// says where it will run (a new, empty folder of its choosing). The user
// chooses only the computer. Then this device carries the files across a
// piece at a time, and the other server starts the session on the same
// conversation. No project comes: the agent clones what it needs there.
// The session it came from is left as it was, for the user to remove once
// the new one works.

import Observation
import VisorProtocol

@MainActor
@Observable
public final class SessionMigration: Identifiable {
    public enum Phase: Equatable {
        /// Asking both servers.
        case preparing
        /// The plan is shown, for the user to go ahead with.
        case ready
        case moving
        /// Moved: the new session's id.
        case done(String)
        case failed(String)
    }

    public nonisolated let id: String
    public let session: SessionInfo
    public let from: AgentServerConnection
    public let to: AgentServerConnection
    public private(set) var phase: Phase = .preparing
    public private(set) var offer: MigrationOffer?
    public private(set) var plan: MigrationPlan?
    /// What is being done now, and how far the move has come (0 to 1).
    public private(set) var doing = ""
    public private(set) var progress = 0.0
    @ObservationIgnored private var carried = 0
    @ObservationIgnored private var total = 1

    /// How much of a file is carried at a time.
    static let piece = 4 << 20
    /// How long to wait before each new try of a piece whose request was
    /// cut short (the connection lost: a phone's SSH tunnel, a network
    /// that came and went), in milliseconds; then the move fails.
    static let retryDelays: [Int32] = [1_000, 3_000, 10_000]

    public init(session: SessionInfo, from: AgentServerConnection, to: AgentServerConnection) {
        id = from.id + "|" + session.id + "|" + to.id
        self.session = session
        self.from = from
        self.to = to
    }

    /// The offer, and the other server's plan for it.
    public func prepare() async {
        phase = .preparing
        do {
            let offer = try await from.server.migrationOffer(for: session.id)
            let plan = try await to.server.migrationPlan(for: offer)
            self.offer = offer
            self.plan = plan
            phase = .ready
        } catch {
            phase = .failed(Self.words(error))
        }
    }

    /// Moves it, as planned.
    public func start() {
        guard phase == .ready, let offer, let plan else { return }
        phase = .moving
        progress = 0
        Task {
            do {
                let moved = try await move(offer, plan)
                phase = .done(moved)
            } catch {
                phase = .failed(Self.words(error))
            }
        }
    }

    private func move(_ offer: MigrationOffer, _ plan: MigrationPlan) async throws -> String {
        total = max(1, offer.size)
        carried = 0
        for file in offer.files {
            doing = "Copying the conversation from \(from.record.name)"
            try await carry(file, offer: offer.token, plan: plan.id)
        }
        doing = "Starting the session on \(to.record.name)"
        let (moved, sessions) = try await to.server.migrationFinish(plan.id)
        to.take(sessions, replacing: true)
        progress = 1
        return moved
    }

    /// A file from the one server to the other, a piece at a time.
    private func carry(_ file: MigrationFile, offer: String, plan: String) async throws {
        guard file.size > 0 else {
            try await to.server.migrationWrite(plan, file: file.id, offset: 0, data: "")
            return
        }
        var offset = 0
        while offset < file.size {
            let at = offset
            let piece = try await retrying {
                try await self.from.server.migrationRead(offer, file: file.id, offset: at, length: min(Self.piece, file.size - at))
            }
            guard piece.next > offset else { throw AgentServerError.message("\(file.id) ended early, at \(offset) bytes") }
            // Written again after a lost answer, the piece is taken as the
            // server has it (it accepts a piece it already holds).
            try await retrying { try await self.to.server.migrationWrite(plan, file: file.id, offset: at, data: piece.data) }
            carried += piece.next - offset
            offset = piece.next
            progress = min(0.99, Double(carried) / Double(total))
        }
    }

    /// `step` tried again after a lost connection, a few times with a wait
    /// between (retryDelays); a server's refusal (its own words) is not tried
    /// again.
    private func retrying<T>(_ step: () async throws -> T) async throws -> T {
        var waits = Self.retryDelays[...]
        while true {
            do {
                return try await step()
            } catch let refusal as AgentServerError {
                throw refusal
            } catch {
                guard let wait = waits.popFirst() else { throw error }
                await to.server.delay(milliseconds: wait)
            }
        }
    }

    private static func words(_ error: Error) -> String {
        if case AgentServerError.message(let text) = error { return text }
        if case AgentServerError.unsupported = error { return "One of the computers does not move sessions yet: update its Visor Server." }
        return "\(error)"
    }
}

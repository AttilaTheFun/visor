// Moving a session from one server to another through this device: the
// session's server offers it (its conversation's files and the projects it
// works in), the other says what it will do with each, and the user
// chooses. Then this device carries the files across a piece at a time,
// has the projects cloned there (or copied, when they cannot be), and the
// other server starts the session on the same conversation. The session
// it came from is left as it was, for the user to remove once the new one
// works.

import Observation
import VisorProtocol

@MainActor
@Observable
public final class SessionMigration: Identifiable {
    public enum Phase: Equatable {
        /// Asking both servers.
        case preparing
        /// The plan is shown, for the user to choose from.
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
    /// The plan's steps as the user has them: each chosen or not.
    public var steps: [MigrationStep] = []
    /// What is being done now, and how far the move has come (0 to 1).
    public private(set) var doing = ""
    public private(set) var progress = 0.0
    @ObservationIgnored private var carried = 0
    @ObservationIgnored private var total = 1

    /// How much of a file is carried at a time.
    static let piece = 4 << 20

    public init(session: SessionInfo, from: AgentServerConnection, to: AgentServerConnection) {
        id = from.id + "|" + session.id + "|" + to.id
        self.session = session
        self.from = from
        self.to = to
    }

    /// Whether the user may leave a step out: not the session's own folder,
    /// nor a project that is there already.
    public func isOptional(_ step: MigrationStep) -> Bool {
        step.project != steps.first?.project && step.action != .present
    }

    /// The offer, and the other server's plan for it.
    public func prepare() async {
        phase = .preparing
        do {
            let offer = try await from.server.migrationOffer(for: session.id)
            let plan = try await to.server.migrationPlan(for: offer)
            self.offer = offer
            self.plan = plan
            steps = plan.steps
            phase = .ready
        } catch {
            phase = .failed(Self.words(error))
        }
    }

    /// Moves it, as planned and chosen.
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
        let chosen = steps.filter(\.chosen)
        let copies = chosen.filter { $0.action == .copy }
        let clones = chosen.filter { $0.action == .clone }
        let sizes = Dictionary(offer.projects.map { ($0.path, $0.size) }, uniquingKeysWith: { first, _ in first })
        total = max(1, offer.size + copies.reduce(0) { $0 + (sizes[$1.project] ?? 0) })
        carried = 0
        for file in offer.files {
            doing = "Copying the conversation from \(from.record.name)"
            try await carry(file, offer: offer.token, plan: plan.id)
        }
        for step in clones {
            doing = "Cloning \(Self.name(of: step)) on \(to.record.name)"
            do {
                try await to.server.migrationClone(plan.id, step: step)
            } catch {
                // A remote the other computer cannot reach: the project
                // goes across as it is here instead.
                try await copy(step, offer: offer, plan: plan)
            }
        }
        for step in copies { try await copy(step, offer: offer, plan: plan) }
        doing = "Starting the session on \(to.record.name)"
        let (moved, sessions) = try await to.server.migrationFinish(plan.id, steps: chosen)
        to.take(sessions, replacing: true)
        progress = 1
        return moved
    }

    private func copy(_ step: MigrationStep, offer: MigrationOffer, plan: MigrationPlan) async throws {
        doing = "Packing \(Self.name(of: step)) on \(from.record.name)"
        let file = try await from.server.migrationPack(offer.token, project: step.project)
        total += file.size
        doing = "Copying \(Self.name(of: step)) to \(to.record.name)"
        try await carry(file, offer: offer.token, plan: plan.id)
        doing = "Unpacking \(Self.name(of: step)) on \(to.record.name)"
        try await to.server.migrationUnpack(plan.id, file: file.id, step: step)
    }

    /// A file from the one server to the other, a piece at a time.
    private func carry(_ file: MigrationFile, offer: String, plan: String) async throws {
        guard file.size > 0 else {
            try await to.server.migrationWrite(plan, file: file.id, offset: 0, data: "")
            return
        }
        var offset = 0
        while offset < file.size {
            let piece = try await from.server.migrationRead(offer, file: file.id, offset: offset, length: min(Self.piece, file.size - offset))
            guard piece.next > offset else { throw AgentServerError.message("\(file.id) ended early, at \(offset) bytes") }
            try await to.server.migrationWrite(plan, file: file.id, offset: offset, data: piece.data)
            carried += piece.next - offset
            offset = piece.next
            progress = min(0.99, Double(carried) / Double(total))
        }
    }

    /// A step's project by its folder's name.
    public static func name(of step: MigrationStep) -> String {
        step.path.split(separator: "/").last.map(String.init) ?? step.path
    }

    private static func words(_ error: Error) -> String {
        if case AgentServerError.message(let text) = error { return text }
        if case AgentServerError.unsupported = error { return "One of the computers does not move sessions yet: update its Visor Server." }
        return "\(error)"
    }
}

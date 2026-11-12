// A session's agent run under agent_protocol's wrapper, as the server sees
// it: an AgentProcess whose other end is the wrapper's stream (AgentDriver).
// What the session sends goes down it (held while no wrapper is connected,
// and sent when one is); what the wrapper says comes up as the events a
// harness here would give, its rows as `.rows`. One per session, kept
// across the wrapper's reconnections.

import AgentProtocol
import Foundation
import VisorAgent
import VisorProtocol

@MainActor
final class DrivenProcess: AgentProcess {
    let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    var skipPermissions = false
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }

    /// The connected wrapper's way down, and its connection's id.
    private var down: (id: UUID, send: (AgentProtocol_V1_DriverMessage) -> Void)?
    /// What waits for a wrapper to connect.
    private var held: [AgentProtocol_V1_DriverMessage] = []
    /// What the wrapper last said it was doing: each change told once.
    private var last = AgentProtocol_V1_EphemeralState()

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    // MARK: - The session's side

    func send(_ text: String) throws {
        deliver(.with { $0.send = .with { $0.id = UUID().uuidString.lowercased(); $0.text = text } })
    }

    /// Nothing to start: the wrapper runs the agent, wherever it is.
    func start() throws {}

    func interrupt() { deliver(.with { $0.interrupt = .init() }) }

    func stop() { deliver(.with { $0.stop = .init() }) }

    func end(within deadline: Duration) async { stop() }

    // MARK: - The wrapper's side

    /// A wrapper connected: what it is sent from now on, and what waited.
    func attach(_ send: @escaping (AgentProtocol_V1_DriverMessage) -> Void) -> UUID {
        let id = UUID()
        down = (id, send)
        let waiting = held
        held = []
        for message in waiting { send(message) }
        return id
    }

    /// The connection `id` ended: sent nothing more until the next.
    func detach(_ id: UUID) {
        guard down?.id == id else { return }
        down = nil
        if last.busy {
            last.busy = false
            continuation.yield(.busy(false))
        }
    }

    /// One thing the wrapper said.
    func take(_ message: AgentProtocol_V1_WrapperMessage) {
        switch message.message {
        case .entries(let rows):
            continuation.yield(.rows(rows.entries.map(Self.row)))
        case .state(let state):
            tell(state)
        case .ended(let why):
            tell(.init())
            continuation.yield(.failure("The agent ended: \(why)."))
        case .hello, .approval, .sessionID, .none:
            break
        }
    }

    private func deliver(_ message: AgentProtocol_V1_DriverMessage) {
        if let down { down.send(message) } else { held.append(message) }
    }

    /// What changed of what it is doing, as a harness's events.
    private func tell(_ state: AgentProtocol_V1_EphemeralState) {
        if state.thinking != last.thinking { continuation.yield(.thinking(state.thinking)) }
        let had = Set(last.tools.map(\.id))
        for tool in state.tools where !had.contains(tool.id) {
            continuation.yield(.toolStarted(id: tool.id, name: tool.name, label: tool.label, tasks: nil))
        }
        let has = Set(state.tools.map(\.id))
        for tool in last.tools where !has.contains(tool.id) { continuation.yield(.toolFinished(id: tool.id)) }
        if state.activity != last.activity { continuation.yield(.activity(state.activity.isEmpty ? nil : state.activity)) }
        if !state.model.isEmpty, state.model != last.model { continuation.yield(.model(state.model)) }
        if state.contextUsed != last.contextUsed || state.contextLimit != last.contextLimit, state.contextUsed > 0 {
            continuation.yield(.context(used: Int(state.contextUsed), limit: state.contextLimit > 0 ? Int(state.contextLimit) : nil))
        }
        // Last, so a turn's end comes after what it did.
        if state.busy != last.busy { continuation.yield(.busy(state.busy)) }
        last = state
    }

    /// A row as the wire has it, as Visor's.
    static func row(_ entry: AgentProtocol_V1_TranscriptEntry) -> TranscriptEntry {
        let role: TranscriptEntry.Role = switch entry.role {
        case .user: .user
        case .tool: .tool
        default: .assistant
        }
        return TranscriptEntry(id: entry.id, role: role, text: entry.text, activities: entry.activities,
                               toolName: entry.toolName.isEmpty ? nil : entry.toolName)
    }
}

// This device's part in the relay: the agents on one server message the
// sessions on another through a device connected to both, and no server
// learns another's address or password. Every few seconds — and at once
// when a server says it has something to carry, or a server connects —
// each server that takes part is told what this device is connected to (a
// DirectoryReport: the other servers and their sessions, by id and name),
// and answers with the messages its agents wrote for those servers. Each
// is carried to its server, which takes it once however many devices
// carry it, and what became of it is carried back.
//
// A server takes part unless the user turned it off for that computer
// (`AgentServerRecord.relay`), or it stands alone; a fork whose devices
// should tell servers nothing turns it off by default (`onByDefault`).

import VisorProtocol
import VisorServices

@MainActor
public final class RelayCourier {
    /// Whether a server takes part when the user has not said: set at
    /// launch, before the store is made.
    public static var onByDefault = true
    /// How often each server is told and asked, in milliseconds.
    static let interval: Int32 = 20_000
    /// How many rounds a server that did not take a report (one from
    /// before the relay answers 404) is left out of: about five minutes.
    static let restRounds = 15

    /// The servers held here.
    private let servers: () -> [AgentServerConnection]
    private var running: Task<Void, Never>?
    /// The servers being told and asked now, by connection id, and those
    /// to be asked again once that is done (a nudge came meanwhile).
    private var exchanging: Set<String> = []
    private var again: Set<String> = []
    /// The messages being carried now, by id.
    private var carrying: Set<String> = []
    /// The servers reported to since they last stopped taking part, by
    /// connection id: one that stops (turned off) is told, once, that this
    /// device reports nothing now.
    private var reported: Set<String> = []
    /// The servers that did not take the last report, by connection id,
    /// with the rounds left before they are asked again: meanwhile neither
    /// told nor told of, nor carried to.
    private var resting: [String: Int] = [:]

    init(servers: @escaping () -> [AgentServerConnection]) {
        self.servers = servers
    }

    /// A server connected (again, perhaps as a newer build): asked at once,
    /// and with it every other, which may hold messages for it.
    func connected(_ connection: AgentServerConnection) async {
        resting[connection.id] = nil
        await exchangeAll()
    }

    /// A server said it has messages to carry: it has the relay, whatever
    /// it answered before, and is asked now.
    func nudged(by connection: AgentServerConnection) async {
        resting[connection.id] = nil
        await exchange(with: connection)
    }

    /// Tells and asks every server in turn, every `interval`, from now on.
    func start() {
        guard running == nil else { return }
        running = Task { [weak self] in
            while !Task.isCancelled {
                guard let courier = self else { return }
                await courier.exchangeAll()
                await Self.pause()
            }
        }
    }

    /// The servers that take part: connected, with an id, not turned off,
    /// and not resting.
    var participants: [AgentServerConnection] {
        servers().filter { $0.state == .connected && !$0.record.serverID.isEmpty && $0.relayEnabled && resting[$0.id] == nil }
    }

    /// What this device tells each server: the servers that take part and
    /// their sessions that an agent can message (not the archived).
    func report() -> DirectoryReport {
        let servers = participants.map { connection in
            DirectoryServer(id: connection.record.serverID, name: connection.record.name, version: connection.serverVersion, sessions: connection.sessions
                .filter { !$0.archived }
                .map { DirectorySession(id: $0.id, name: $0.title.isEmpty ? $0.agent.title : $0.title, agent: $0.agent.title, busy: $0.busy) })
        }
        return DirectoryReport(client: AgentServerRecord.clientID, clientName: VisorHost.deviceName, clientVersion: Self.said(VisorHost.appVersion),
                               clientPlatform: Self.said(VisorHost.platformName), servers: servers)
    }

    /// What the host said, or nothing.
    private static func said(_ value: String) -> String? { value.isEmpty ? nil : value
    }

    /// Every server that takes part, told and asked; one turned off since
    /// it was last told, told that there is nothing.
    public func exchangeAll() async {
        for (id, rounds) in resting { resting[id] = rounds > 1 ? rounds - 1 : nil }
        let taking = participants
        for connection in servers() where reported.contains(connection.id) && resting[connection.id] == nil
            && !taking.contains(where: { $0 === connection }) {
            reported.remove(connection.id)
            guard connection.state == .connected, connection.offersRelay else { continue }
            _ = try? await connection.server.relay(DirectoryReport(client: AgentServerRecord.clientID, clientName: VisorHost.deviceName, servers: []))
        }
        for connection in taking { await exchange(with: connection) }
    }

    /// One server told what this device is connected to, and the messages
    /// it has for those servers carried there. Asked while it is being
    /// asked already, it is asked again once that is done.
    public func exchange(with source: AgentServerConnection) async {
        guard participants.contains(where: { $0 === source }) else { return }
        guard exchanging.insert(source.id).inserted else {
            again.insert(source.id)
            return
        }
        repeat {
            again.remove(source.id)
            do {
                let messages = try await source.server.relay(report())
                reported.insert(source.id)
                for message in messages { await carry(message, from: source) }
            } catch {
                source.note("the relay report was not taken (asked again in a few minutes): \(error)")
                resting[source.id] = Self.restRounds
                again.remove(source.id)
            }
        } while again.contains(source.id)
        exchanging.remove(source.id)
    }

    /// A message to the server it is for, and what became of it back to
    /// the one it came from. One for a server not connected here is left
    /// for another device (or this one, later).
    private func carry(_ message: RelayMessage, from source: AgentServerConnection) async {
        guard let destination = participants.first(where: { $0.record.serverID == message.to.server }),
              carrying.insert(message.id).inserted else { return }
        do {
            let receipt = try await destination.server.deliver(message)
            try await source.server.confirm(receipt)
            source.note("carried a message to \(destination.record.name): \(receipt.outcome.rawValue)")
        } catch {
            source.note("a message for \(destination.record.name) was not carried: \(error)")
        }
        carrying.remove(message.id)
    }

    private static func pause() async {
        guard let socket = VisorHost.socket else {
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            return
        }
        await socket.delay(milliseconds: interval)
    }
}

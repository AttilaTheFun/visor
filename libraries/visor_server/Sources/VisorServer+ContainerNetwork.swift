// A session's container's network, looked after (docs/container-host.md):
// when its agent's turn fails on the network, the container host is asked
// whether the container's network works. If it doesn't, the container is
// made again — the session's folder and its disk as they were — and the
// agent started again there; if that fails too, the session says so. Not
// twice in five minutes for one session: an agent must not sit failing every
// turn, nor its container be made again every turn.

import Foundation
import VisorProtocol

extension VisorServer {
    /// What an agent's failure says when it couldn't reach anything.
    static let networkFailures = ["EAI_AGAIN", "ENOTFOUND", "ECONNREFUSED", "ETIMEDOUT", "ENETUNREACH", "EHOSTUNREACH",
                                  "Can't reach the API server", "Could not resolve host", "Temporary failure in name resolution"]

    static func isNetworkFailure(_ message: String) -> Bool {
        networkFailures.contains { message.localizedCaseInsensitiveContains($0) }
    }

    /// After an agent's event: a turn of a session in a container that
    /// failed on the network has the container's network checked.
    func noteContainerNetwork(after event: AgentEvent, of record: SessionRecord) {
        guard case .failure(let message) = event, Self.isNetworkFailure(message), let container = record.info.container,
              container.socket == nil, let host = containerHost else { return }
        if let last = containersRemade[record.info.id], ContinuousClock.now - last < .seconds(300) { return }
        containersRemade[record.info.id] = .now
        Task { await checkNetwork(of: record, container: container, host: host) }
    }

    /// The container's network asked of its host, and the container made
    /// again when it has none.
    func checkNetwork(of record: SessionRecord, container: SessionContainer, host: ContainerHost) async {
        let network = try? await host.network(container.id)
        if network?.ok == true { return }
        Self.log("session \(record.info.title): its container \(container.id) has no network (\(network?.detail ?? "its host didn't say")); making it again")
        do {
            let made = try await makeContainer(session: record.info.id, agent: record.info.agent, folder: record.info.cwd,
                                               size: container.size ?? .standard, keepingDisk: true)
            // Moved out or ended meanwhile: the new one isn't wanted.
            guard record.info.container?.id == container.id, sessions.contains(where: { $0 === record }) else {
                return removeContainer(made)
            }
            record.info.container = made
            record.placed()
            broadcast(record.apply(.notice("Its container had lost its network: it was made again, its folder and disk as they were.")),
                      session: record)
            rebuild(record) {}
        } catch {
            broadcast(record.apply(.notice("Its container has no network, and making it again failed: \(error)")), session: record)
        }
        saveArchive()
        broadcastSessions()
    }
}

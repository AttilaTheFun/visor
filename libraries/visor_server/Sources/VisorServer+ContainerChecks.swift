// A session's container, looked after (docs/container-host.md): when its
// agent's turn fails on the network, or its agent ends with a failing
// status, the container host is asked whether the container is still there
// (its `ls`) and whether its network works. A container that is gone (its
// host lost it, or someone removed it) or has no network is made again —
// the session's folder, and its disk where that was kept — and the agent
// started again there; if that fails too, the session says so. Not twice in
// five minutes for one session: an agent must not sit failing every turn,
// nor its container be made again every turn.

import Foundation
import VisorProtocol

extension VisorServer {
    /// What an agent's failure says when it couldn't reach anything.
    static let networkFailures = ["EAI_AGAIN", "ENOTFOUND", "ECONNREFUSED", "ETIMEDOUT", "ENETUNREACH", "EHOSTUNREACH",
                                  "Can't reach the API server", "Could not resolve host", "Temporary failure in name resolution"]

    /// What an agent's failure says when its program ended with a status
    /// (ClaudeProcess, CodexAppServerProcess): in a container, perhaps one
    /// that is gone, its host's `exec` failing.
    static let exitFailures = ["exited with status", "app server exited (status"]

    static func isNetworkFailure(_ message: String) -> Bool {
        networkFailures.contains { message.localizedCaseInsensitiveContains($0) }
    }

    static func isExitFailure(_ message: String) -> Bool {
        exitFailures.contains { message.contains($0) }
    }

    /// After an agent's event: a session in a container whose turn failed
    /// on the network, or whose agent ended failing, has its container
    /// checked.
    func noteContainer(after event: AgentEvent, of record: SessionRecord) {
        guard case .failure(let message) = event, Self.isNetworkFailure(message) || Self.isExitFailure(message),
              let container = record.info.container, container.socket == nil, let host = containerHost else { return }
        if let last = containersRemade[record.info.id], ContinuousClock.now - last < .seconds(300) { return }
        containersRemade[record.info.id] = .now
        Task { await checkContainer(of: record, container: container, host: host) }
    }

    /// Whether the container is there and its network works, asked of its
    /// host; the container made again when it is gone or has none. A host
    /// that can't list its containers is taken to still have it.
    func checkContainer(of record: SessionRecord, container: SessionContainer, host: ContainerHost) async {
        let gone = (try? await host.list()).map { !$0.contains { $0.id == container.id } } ?? false
        if !gone {
            let network = try? await host.network(container.id)
            if network?.ok == true { return }
            Self.log("session \(record.info.title): its container \(container.id) has no network (\(network?.detail ?? "its host didn't say")); making it again")
        } else {
            Self.log("session \(record.info.title): its container \(container.id) is gone; making it again")
        }
        do {
            let made = try await makeContainer(session: record.info.id, agent: record.info.agent, folder: record.info.cwd,
                                               size: container.size ?? .standard, keepingDisk: true)
            // Moved out or ended meanwhile: the new one isn't wanted.
            guard record.info.container?.id == container.id, sessions.contains(where: { $0 === record }) else {
                return removeContainer(made)
            }
            record.info.container = made
            record.placed()
            broadcast(record.apply(.notice(gone ? "Its container was gone: it was made again, its folder as it was (and its disk, if that was kept). "
                                                  + "Say again what didn't reach the agent."
                                                : "Its container had lost its network: it was made again, its folder and disk as they were.")),
                      session: record)
            rebuild(record) {}
        } catch {
            broadcast(record.apply(.notice(gone ? "Its container is gone, and making it again failed: \(error). Run on the Computer runs its agent here instead."
                                                : "Its container has no network, and making it again failed: \(error)")), session: record)
        }
        saveArchive()
        broadcastSessions()
    }
}

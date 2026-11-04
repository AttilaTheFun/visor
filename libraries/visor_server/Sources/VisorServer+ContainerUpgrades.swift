// A session's container made again from the image it would be made from
// now (docs/co-tenancy.md, "Container images"): when that isn't the one it
// was made from (the setting changed, or this server is another version and
// so wants its own version's), or Visor's own Linux programs are here now
// and it was made without them. Never mid-turn: when the server finds its
// containers, and when a session's turn ends. The container is made again
// with its disks kept (the agent's home and Bazel's output), so the agent
// resumes where it was; the session is told. When the new image can't be
// had, the container is made again from the one it had, and the new one
// isn't tried again until another is wanted.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Whether a container is behind what this server would make it from.
    func containerIsBehind(_ container: SessionContainer) -> Bool {
        guard container.socket == nil else { return false }
        if container.image != wantedContainerImage { return true }
        return container.programs == nil && Self.containerPrograms() != nil
    }

    /// Every session whose container is behind and whose agent isn't
    /// working: its container made again.
    func upgradeContainers() {
        for record in sessions where !record.info.busy {
            upgradeContainer(of: record)
        }
    }

    /// After an agent's event: a session whose turn has just ended has its
    /// container made again, if it's behind.
    func noteContainerUpgrade(after event: AgentEvent, of record: SessionRecord) {
        guard case .busy(false) = event else { return }
        upgradeContainer(of: record)
    }

    /// A session's container made again from the image wanted now, its
    /// disks kept, if it's behind, its agent isn't working, and that image
    /// hasn't failed it before.
    func upgradeContainer(of record: SessionRecord) {
        let session = record.info.id
        let wanted = wantedContainerImage
        guard let container = record.info.container, !record.info.busy, containerIsBehind(container), containerHost != nil,
              containerProblem == nil, !containersUpgrading.contains(session), containerUpgradeFailed[session] != wanted else { return }
        containersUpgrading.insert(session)
        Self.log("session \(record.info.title): its container \(container.id) is from \(container.image ?? "an image it didn't say"); making it again from \(wanted)")
        Task {
            defer { containersUpgrading.remove(session) }
            // The old one goes first, its disks kept for the new one.
            if let host = containerHost { try? await host.remove(container.id, volumes: false) }
            let made: SessionContainer
            let notice: String
            do {
                made = try await makeContainer(session: session, agent: record.info.agent, folder: record.info.cwd,
                                               size: container.size ?? .standard, keepingDisk: true, image: wanted)
                notice = "Its container was made again from \(wanted): its folder and disks as they were."
            } catch {
                containerUpgradeFailed[session] = wanted
                Self.log("session \(record.info.title): its container couldn't be made from \(wanted): \(error)")
                // The old one went first: made again from its own image.
                do {
                    made = try await makeContainer(session: session, agent: record.info.agent, folder: record.info.cwd,
                                                   size: container.size ?? .standard, keepingDisk: true, image: container.image)
                    notice = "Its container couldn't be made from \(wanted) (\(error)): it was made again from \(container.image ?? "the image it had"), its folder and disks as they were."
                } catch {
                    broadcast(record.apply(.notice("Its container couldn't be made again, from \(wanted) or the image it had: \(error). "
                                                   + "Run on the Computer runs its agent here instead.")), session: record)
                    saveArchive()
                    broadcastSessions()
                    return
                }
            }
            // Moved out or ended meanwhile: the new one isn't wanted.
            guard record.info.container?.id == container.id, sessions.contains(where: { $0 === record }) else {
                return removeContainer(made)
            }
            record.info.container = made
            record.placed()
            broadcast(record.apply(.notice(notice)), session: record)
            rebuild(record) {}
            saveArchive()
            broadcastSessions()
        }
    }
}

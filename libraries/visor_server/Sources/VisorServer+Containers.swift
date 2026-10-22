// Sessions whose agents run in containers on an oss server (OS Server,
// AttilaTheFun/oss) rather than on this computer. oss hosts the
// containers; this server drives them over oss's API: it makes a session
// there (a container, the repository cloned into /root/work), writes
// Visor's MCP script into its home, and runs the agent there as a process
// whose input it writes and whose output it reads on from where it was
// left (OSSChild) — through a restart of this server too. The agent has
// Visor's tools, and oss's for leasing machines.
//
//     visor-server oss <url> <token file>    the oss server, and its token
//     visor-server oss image <name> | -      the image containers are made from
//     visor-server oss callback <ws-url> | -  how a container reaches this server

import Foundation
import VisorProtocol

extension VisorServer {
    /// The oss server sessions' agents can run on, when one is set and its
    /// token kept.
    var ossClient: OSSClient? {
        let server = settings.ossServer.trimmingCharacters(in: .whitespaces)
        guard !server.isEmpty, let token = Self.secrets.get("ossToken"), !token.isEmpty else { return nil }
        return OSSClient(server: server.hasSuffix("/") ? String(server.dropLast()) : server, token: token)
    }

    /// Whether a session can be started in a container here.
    public var containersAvailable: Bool { ossClient != nil }

    /// Whether oss's token is kept.
    public var ossTokenKept: Bool { !(Self.secrets.get("ossToken") ?? "").isEmpty }

    /// Keeps oss's token (with the server's secrets); nil or empty lets it go.
    public func setOSSToken(_ token: String?) {
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Self.secrets.set("ossToken", token.isEmpty ? nil : token)
    }

    /// How Visor's tools in a container reach this server: the address
    /// set, else this computer's LAN address (a container resolves no
    /// `.local` names) at the server's port.
    public var containerServerURL: String {
        let set = settings.ossCallback.trimmingCharacters(in: .whitespaces)
        if !set.isEmpty { return set }
        let addresses = ServerPlatform.current.host.networkAddresses()
        let address = addresses.first { $0.kind == .lan }?.address ?? addresses.first?.address ?? "127.0.0.1"
        return "ws://\(address):\(port)"
    }

    /// Where a session's agent runs, when that is a container.
    func placement(for info: SessionInfo) -> ContainerPlacement? {
        guard let container = info.container else { return nil }
        return ContainerPlacement(server: container.server, session: container.id, serverURL: containerServerURL)
    }

    /// The folder a session works in, in its container: the repository's
    /// clone, or `/root/work` with none.
    static func containerFolder(repository: String?) -> String {
        guard let name = repository?.split(separator: "/").last, !name.isEmpty else { return "/root/work" }
        return "/root/work/" + name
    }

    /// Starts a session whose agent runs in a container on oss: oss makes
    /// it (the repository cloned in), Visor's MCP script is written into
    /// it, and the session is added; `done` is told the session, or why
    /// not. The agent starts with its first message, as on this computer.
    func startInContainer(_ envelope: Envelope, from client: ClientConnection?, done: @escaping @MainActor (Result<SessionRecord, OSSClient.Failure>) -> Void) {
        guard let agent = envelope.agent else { return done(.failure(OSSClient.Failure(words: "Which agent?"))) }
        guard let oss = ossClient else {
            return done(.failure(OSSClient.Failure(words: "This computer has no oss server to run agents in containers on: visor-server oss <url> <token file>.")))
        }
        let id = envelope.id ?? UUID().uuidString
        let repository = envelope.repository?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let image = settings.ossImage.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let given = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = given.isEmpty ? "\(agent.title) in \(repository.map { String($0.split(separator: "/").last ?? "") } ?? "a container")" : String(given.prefix(60))
        let skip = envelope.skipPermissions ?? true
        Task {
            do {
                let made = try await oss.makeSession(agent: agent.rawValue, labels: ["visor.session": id], repository: repository, image: image)
                try await oss.writeFile(made, path: String(ContainerPlacement.scriptPath.dropFirst("/root/".count)), data: Data(VisorMCPScript.source.utf8))
                var info = SessionInfo(id: id, agent: agent, cwd: Self.containerFolder(repository: repository), title: title, skipPermissions: skip,
                                       created: Date().timeIntervalSince1970)
                info.container = SessionContainer(server: oss.server, id: made, repository: repository, image: image)
                let record = SessionRecord(info: info, process: makeProcess(info, resume: nil), entries: [])
                sessions.append(record)
                if let client { record.subscribers.insert(ObjectIdentifier(client)) }
                Self.log("session started in a container on \(oss.server): \(title) (\(agent.title))\(repository.map { ", \($0) cloned" } ?? "")")
                saveArchive()
                broadcastSessions()
                done(.success(record))
            } catch let failure as OSSClient.Failure {
                done(.failure(failure))
            } catch {
                done(.failure(OSSClient.Failure(words: error.localizedDescription)))
            }
        }
    }

    /// Picks up the agent an earlier launch left running in its container,
    /// reading on from where that launch left off.
    func pickUp(_ record: SessionRecord, container stored: StoredContainerProcess) {
        defer { record.leftContainer = nil }
        guard let placement = placement(for: record.info), let hostable = record.process as? HostableProcess else {
            Self.log("could not pick up the agent of \(record.info.title) (\(record.info.id)) in its container: \(record.info.container == nil ? "no container" : "no adapter for it")")
            return release(record)
        }
        if !record.isBound { bind(record) }
        hostable.adopt(OSSChild.attach(server: placement.server, token: ContainerPlacement.token, session: placement.session,
                                       process: stored.process, out: stored.out, err: stored.err),
                       carried: stored.carried ?? [:])
        record.followFile()
        Self.log("picked up the agent of \(record.info.title) (\(record.info.id)) in its container")
        if record.interrupted { broadcast(record.apply(.busy(true)), session: record) }
        release(record)
    }

    /// A session's container gone with it (its session ended here).
    func removeContainer(of info: SessionInfo) {
        guard let container = info.container, let placement = placement(for: info) else { return }
        Task {
            do {
                try await placement.client.removeSession(container.id)
                Self.log("removed the container of \(info.title) on \(container.server)")
            } catch {
                Self.log("could not remove the container of \(info.title) on \(container.server): \(error.localizedDescription)")
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

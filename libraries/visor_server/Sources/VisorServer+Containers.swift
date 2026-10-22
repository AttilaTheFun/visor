// Sessions whose agents run in containers on an oss server (OS Server,
// AttilaTheFun/oss) rather than on this computer. oss hosts the
// containers; this server drives them over oss's API (OSSClient): it makes
// a container from Visor's agent image (tools/oss/visor-agent), clones the
// repository into /root/work, writes Visor's MCP script into its home, and
// runs the agent there as a process whose input it writes and whose output
// it reads on from where it was left (OSSChild) — through a restart of
// this server too. The agent has Visor's tools, and oss's for leasing
// machines.
//
//     visor-server oss <url> <token file>    the oss server, and its token
//     visor-server oss image <name> | -      the image containers are made from (visor-agent)
//     visor-server oss callback <ws-url> | -  how a container reaches this server

import Foundation
import OSSClient
import VisorProtocol

extension VisorServer {
    /// The image a container is made from unless another is set: Visor's
    /// own (tools/oss/visor-agent), with the agents in it, built on the oss
    /// server under this name; oss's own default is a plain Linux.
    public nonisolated static let containerImage = "visor-agent"

    /// The oss server sessions' agents can run on, when one is set (at an
    /// address that is a URL) and its token kept.
    var ossClient: OSSClient? {
        guard let server = settings.ossServer.trimmingCharacters(in: .whitespaces).nilIfEmpty, !(Self.secrets.get("ossToken") ?? "").isEmpty else { return nil }
        return ContainerPlacement.client(server: server)
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
        return ContainerPlacement(server: container.server, container: container.id, serverURL: containerServerURL)
    }

    /// The folder a session works in, in its container: the repository's
    /// clone, or `/root/work` with none.
    static func containerFolder(repository: String?) -> String {
        guard let name = repository.map(repositoryName), !name.isEmpty else { return "/root/work" }
        return "/root/work/" + name
    }

    /// What oss clones: a repository given as GitHub's `owner/name` at its
    /// GitHub address, and a git URL of any host as it is.
    static func cloneURL(repository: String) -> String {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts.contains(where: \.isEmpty), !repository.contains(":"), !repository.hasPrefix(".") else { return repository }
        return "https://github.com/\(repository).git"
    }

    /// A repository's name, as git names its clone: the last part of its
    /// path or URL, without `.git`.
    static func repositoryName(_ repository: String) -> String {
        let last = repository.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    /// Starts a session whose agent runs in a container on oss: oss makes
    /// the container, the repository is cloned into it, its SSH key made
    /// and Visor's MCP script written, and the session is added; `done` is
    /// told the session, or why not. The agent starts with its first
    /// message, as on this computer.
    func startInContainer(_ envelope: Envelope, from client: ClientConnection?, done: @escaping @MainActor (Result<SessionRecord, OSSError>) -> Void) {
        guard let agent = envelope.agent else { return done(.failure(OSSError(status: 0, message: "Which agent?"))) }
        guard let oss = ossClient else {
            return done(.failure(OSSError(status: 0, message: "This computer has no oss server to run agents in containers on: visor-server oss <url> <token file>.")))
        }
        let id = envelope.id ?? UUID().uuidString
        let repository = envelope.repository?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let image = settings.ossImage.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Self.containerImage
        let server = settings.ossServer.trimmingCharacters(in: .whitespaces)
        let given = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = given.isEmpty ? "\(agent.title) in \(repository.map(Self.repositoryName) ?? "a container")" : String(given.prefix(60))
        let skip = envelope.skipPermissions ?? true
        Task {
            do {
                // Made from an image the oss server has (built there), which
                // can take a while the first time.
                var making = oss
                making.timeout = 300
                let made = try await making.startContainer(ContainerRequest(holder: "visor", image: image, labels: ["visor.session": id])).id
                do {
                    if let repository {
                        try await oss.clone(made, url: Self.cloneURL(repository: repository), into: Self.containerFolder(repository: repository))
                    }
                    try await oss.makeSSHKey(made)
                    try await oss.writeFile(made, String(ContainerPlacement.scriptPath.dropFirst("/root/".count)), Data(VisorMCPScript.source.utf8))
                } catch {
                    // No session here to end it: the container goes now.
                    try? await oss.remove(container: made)
                    throw error
                }
                var info = SessionInfo(id: id, agent: agent, cwd: Self.containerFolder(repository: repository), title: title, skipPermissions: skip,
                                       created: Date().timeIntervalSince1970)
                info.container = SessionContainer(server: server, id: made, repository: repository, image: image)
                let record = SessionRecord(info: info, process: makeProcess(info, resume: nil), entries: [])
                sessions.append(record)
                if let client { record.subscribers.insert(ObjectIdentifier(client)) }
                Self.log("session started in a container on \(server): \(title) (\(agent.title))\(repository.map { ", \($0) cloned" } ?? "")")
                saveArchive()
                broadcastSessions()
                done(.success(record))
            } catch let error as OSSError {
                // oss's own refusals say they are oss's.
                done(.failure(error.status == 0 ? error : OSSError(status: error.status, message: "oss: \(error.message)")))
            } catch {
                done(.failure(OSSError(status: 0, message: error.localizedDescription)))
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
        hostable.adopt(OSSChild.attach(client: placement.client, container: placement.container,
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
                try await placement.client.remove(container: container.id)
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

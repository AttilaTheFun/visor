// Sessions whose agents run in Linux containers rather than on this computer
// directly: each a lease from the oss server (OS Server) on this computer,
// which runs it (a helper of its own per container, apart from oss), made
// from Visor's agent image (tools/containers/visor-agent, published by CI to
// ghcr.io) and held while the session lasts. The agent runs in it under a
// host of its own, as any agent does, through OS Server's command line on the
// container's own socket, so it outlives a restart of this server and of OS
// Server. The container sees the session's folder at the same path, the
// agent's log folder, and Visor's tools (ContainerTools), and nothing else of
// the Mac: Apple apps build there with rules_applecross from Xcode's SDKs an
// OS Server serves, not the Mac's Xcode. The agent works on the same files
// and keeps the same log whichever side it runs on, so a session moves into
// or out of its container by starting its agent again on the other side.
//
//     visor-server containers image <ref> | -     the image containers are made from (Visor's)
//     visor-server containers callback <ws-url> | -  how a container reaches this server

import ClaudeTranscript
import Foundation
import OSSClient
import VisorProtocol

extension VisorServer {
    /// Where Visor's own agent image is published (by CI, for each build
    /// as its version, and as its MAJOR.MINOR for the latest of those).
    public nonisolated static let containerImageRepository = "ghcr.io/attilathefun/visor-agent"

    /// Visor's own image for a server of `version` ("0.40.12"): that
    /// build's, or its MAJOR.MINOR's latest for a build CI did not number
    /// (0.40.0), or the latest of all where the binary says no version.
    public nonisolated static func containerImage(version: String) -> String {
        let numbers = version.prefix { $0.isNumber || $0 == "." }.split(separator: ".").map(String.init)
        guard numbers.count >= 2 else { return containerImageRepository + ":latest" }
        let build = numbers.count > 2 ? Int(numbers[2]) ?? 0 : 0
        return containerImageRepository + ":" + (build > 0 ? numbers.prefix(3) : numbers.prefix(2)).joined(separator: ".")
    }

    /// The image a container is made from unless another is set: Visor's
    /// own, this server's version's.
    public var defaultContainerImage: String { Self.containerImage(version: ServerPlatform.current.host.version) }

    /// Whether a session can run in a container here (as last found).
    public var containersAvailable: Bool { containerProblem == nil }

    /// Finds again whether containers can run here, and tells the clients
    /// when that changed: an OS Server on this computer that lends them.
    public func checkContainers() async {
        var problem: String?
        if ServerPlatform.current.containerExec == nil {
            problem = "this system runs no containers"
        } else if let pool = ossPool {
            let here = await pool.reach().filter { $0.distance == .thisComputer }
            if here.isEmpty {
                problem = "no OS Server on this computer answers (install OS Server, and add it in Visor Server's settings with its token)"
            } else if !here.contains(where: { $0.lends(.container, config: nil) }) {
                problem = "the OS Server on this computer lends no containers (OS Server 0.9 or later)"
            }
        } else {
            problem = "no oss server is set (this computer's OS Server, in Visor Server's settings)"
        }
        // An agent in a container reaches this server over the network.
        if problem == nil, !settings.reachableFromNetwork, settings.containerCallback.trimmingCharacters(in: .whitespaces).isEmpty {
            problem = "an agent in a container reaches this server over the network: turn on “Reachable from the network”"
        }
        guard problem != containerProblem else { return }
        let was = containersAvailable
        containerProblem = problem
        Self.log(problem.map { "containers: none (\($0))" } ?? "containers: ready")
        // The clients hear only whether a session can start in one.
        if containersAvailable != was { broadcastSessions() }
    }

    /// How Visor's tools in a container reach this server: the address
    /// set, else this computer's LAN address (a container resolves no
    /// `.local` names) at the server's port.
    public var containerServerURL: String {
        let set = settings.containerCallback.trimmingCharacters(in: .whitespaces)
        if !set.isEmpty { return set }
        let addresses = ServerPlatform.current.host.networkAddresses()
        let address = addresses.first { $0.kind == .lan }?.address ?? addresses.first?.address ?? "127.0.0.1"
        return "ws://\(address):\(port)"
    }

    /// Where a session's agent runs, when that is a container.
    func placement(for info: SessionInfo) -> ContainerPlacement? {
        guard let container = info.container, let socket = container.socket, let exec = ServerPlatform.current.containerExec else { return nil }
        return ContainerPlacement(name: container.id, socket: socket, serverURL: containerServerURL, exec: exec)
    }

    /// The name of a session's container, and of its disk's volume with
    /// "-build" after it.
    static func containerName(session: String) -> String {
        "visor-" + session.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// What a session's container sees of this computer: its folder, at
    /// the same path; the agent's log folder for it, where the agent there
    /// keeps its log; and Visor's tools.
    static func containerMounts(agent: AgentKind, folder: String, tools: URL) -> [ContainerMount] {
        var mounts = [ContainerMount(source: folder, destination: folder)]
        switch agent {
        case .codex:
            // Codex's home in the containers (their own sign-in, one for
            // all: its refreshes go to one file), then the computer's
            // sessions folder in it, where the session's log is kept.
            let sessions = SessionCatalog.codexRoot().appendingPathComponent("sessions", isDirectory: true)
            try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            mounts.append(ContainerMount(source: ContainerSignIns.codexHome.path, destination: "/root/.codex"))
            mounts.append(ContainerMount(source: sessions.path, destination: "/root/.codex/sessions"))
        case .openrouter:
            // The same for openrouter: its home in the containers (their
            // key), the computer's sessions folder in it.
            let sessions = SessionCatalog.openrouterRoot.appendingPathComponent("sessions", isDirectory: true)
            try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            mounts.append(ContainerMount(source: ContainerSignIns.openrouterHome.path, destination: "/root/.openrouter"))
            mounts.append(ContainerMount(source: sessions.path, destination: "/root/.openrouter/sessions"))
        case .claude:
            // Where this computer's Claude keeps the folder's log (by its
            // real path), at the name Claude in the container gives it (the
            // path as mounted, no links in it: /tmp, say, is /private/tmp
            // here and itself there).
            let name = ClaudeSessionFiles.projectDirectoryName(for: folder)
            let project = ClaudeSessionFiles.projectsRoot().appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let seen = ClaudeSessionFiles.projectDirectoryName(for: folder, followingLinks: false)
            mounts.append(ContainerMount(source: project.path, destination: "/root/.claude/projects/" + seen))
        }
        mounts.append(ContainerMount(source: tools.path, destination: ContainerPlacement.toolsFolder, readOnly: true))
        return mounts
    }

    /// Makes the container a session's agent runs in: leased from the OS
    /// Server on this computer (held until released), from the image, with
    /// its mounts and a disk of its own for builds, the sign-ins for
    /// containers copied into its home, and an SSH key of its own (for the
    /// machines it leases). Released again when any of that fails.
    func makeContainer(session: String, agent: AgentKind, folder: String, size: ContainerSize = .standard) async throws -> SessionContainer {
        if containerProblem != nil { await checkContainers() }
        if let containerProblem { throw ContainerFailure(message: "This computer cannot run containers: \(containerProblem).") }
        guard let exec = ServerPlatform.current.containerExec, let pool = ossPool, let tools = ContainerTools.folder else {
            throw ContainerFailure(message: "This computer cannot run containers.")
        }
        let resolved = HostFolders.resolve(folder)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isFolder), isFolder.boolValue else {
            throw ContainerFailure(message: "There is no folder \(folder) on this computer.")
        }
        let name = Self.containerName(session: session)
        let image = settings.containerImage.trimmingCharacters(in: .whitespaces).isEmpty ? defaultContainerImage : settings.containerImage
        let holder = Self.leaseHolder(session: session)
        // One left by an earlier attempt goes first.
        await releaseContainers(held: holder)
        // What it is given, within what this computer has.
        let given = Self.fitted(size)
        let spec = ContainerSpec(image: image, cpus: given.cpus, memoryBytes: given.memoryBytes,
                                 mounts: Self.containerMounts(agent: agent, folder: resolved, tools: tools),
                                 // Its disk for builds goes with the lease.
                                 volumes: [ContainerVolume(name: name + "-build", destination: ContainerPlacement.buildOutput,
                                                           sizeBytes: given.diskBytes)],
                                 rosetta: true)
        let client: OSSClient
        let lease: Lease
        do {
            (client, lease) = try await pool.lease(LeaseRequest(platform: .container, minutes: 0, holder: holder, container: spec))
        } catch let error as OSSError {
            throw ContainerFailure(message: Self.containerRefusal(error) ?? "Could not make the container from \(image): \(error.message)")
        } catch {
            throw ContainerFailure(message: "Could not make the container from \(image): \(error.localizedDescription)")
        }
        leaseClients[lease.id] = client
        do {
            guard let socket = lease.execSocket else { throw ContainerFailure(message: "OS Server gave the container no socket to run commands in.") }
            // The sign-ins for containers, then oss's Bazel cache.
            for file in ContainerSignIns.homeFiles() + (await buildCacheFiles()) {
                let path = "/root/" + file.path
                let wrote = try await exec.execute(socket: socket, ["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\" && chmod 600 \"$1\"", "sh", path],
                                                   input: file.data)
                guard wrote.status == 0 else { throw ContainerFailure(message: "Could not write \(path) in the container: \(wrote.output)") }
            }
            let key = try await exec.execute(socket: socket, ["sh", "-c", "test -f /root/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -C visor-container -f /root/.ssh/id_ed25519"],
                                             input: nil)
            guard key.status == 0 else { throw ContainerFailure(message: "Could not make the container's SSH key: \(key.output)") }
            return SessionContainer(id: lease.id, image: image, size: given, socket: socket)
        } catch {
            await releaseContainer(lease.id)
            throw error
        }
    }

    /// What oss's refusal to lend a container means here, in words New
    /// Session shows; nil for any other failure.
    nonisolated static func containerRefusal(_ error: OSSError) -> String? {
        switch error.code {
        case "busy": "This Mac's OS Server has no room for another container: end a session in one, or move it out, first."
        case "notLocal": "Containers come only from the OS Server on this Mac, and none answers here."
        case "noContainers": "The OS Server on this Mac runs no containers (OS Server 0.9 or later does)."
        default: nil
        }
    }

    /// Releases the containers `holder` holds (an earlier attempt's, left
    /// behind).
    private func releaseContainers(held holder: String) async {
        for client in ossClients {
            guard let held = try? await client.leases() else { continue }
            for lease in held where lease.holder == holder && lease.platform == .container {
                try? await client.release(lease.id)
                leaseClients[lease.id] = nil
            }
        }
    }

    /// Releases a session's container, and its disk with it.
    private func releaseContainer(_ id: String) async {
        guard let client = await lender(of: id) else { return }
        try? await client.release(id)
        leaseClients[id] = nil
    }

    /// A size asked for, within what this computer has: no more cores than
    /// it has, no more memory than it has but 4 GB (for itself), whole
    /// gigabytes, and at least a core, 2 GB of memory and 16 GB of disk.
    static func fitted(_ size: ContainerSize, cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                       memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ContainerSize {
        let gigabyte = ContainerSize.gigabyte
        func whole(_ bytes: Int64) -> Int64 { (bytes + gigabyte / 2) / gigabyte * gigabyte }
        let most = max(2 * gigabyte, (Int64(clamping: memory) - 4 * gigabyte) / gigabyte * gigabyte)
        return ContainerSize(cpus: min(max(size.cpus, 1), max(cores, 1)), memoryBytes: min(max(whole(size.memoryBytes), 2 * gigabyte), most),
                             diskBytes: max(whole(size.diskBytes), 16 * gigabyte))
    }

    /// Starts a session whose agent runs in a container here, in the folder
    /// the envelope names: the container is made, and the session added;
    /// `done` is told the session, or why not. The agent starts with its
    /// first message, as on this computer.
    func startInContainer(_ envelope: Envelope, from client: ClientConnection?, done: @escaping @MainActor (Result<SessionRecord, ContainerFailure>) -> Void) {
        guard let agent = envelope.agent else { return done(.failure(ContainerFailure(message: "Which agent?"))) }
        guard let cwd = envelope.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty else {
            return done(.failure(ContainerFailure(message: "Which folder?")))
        }
        let id = envelope.id ?? UUID().uuidString
        let given = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = given.isEmpty ? "\(agent.title) in a container" : String(given.prefix(60))
        let skip = envelope.skipPermissions ?? true
        Task {
            do {
                let container = try await makeContainer(session: id, agent: agent, folder: cwd, size: envelope.containerSize ?? .standard)
                var info = SessionInfo(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skip, created: Date().timeIntervalSince1970)
                info.container = container
                let record = SessionRecord(info: info, process: makeProcess(info, resume: nil), entries: [])
                sessions.append(record)
                if let client { record.subscribers.insert(ObjectIdentifier(client)) }
                Self.log("session started in a container (\(container.id)): \(title) (\(agent.title)) in \(cwd)")
                saveArchive()
                broadcastSessions()
                done(.success(record))
            } catch let failure as ContainerFailure {
                done(.failure(failure))
            } catch {
                done(.failure(ContainerFailure(message: error.localizedDescription)))
            }
        }
    }

    /// Moves a session's agent into a container here (`into`) of `size`, or
    /// out of its container onto this computer: the same folder and
    /// conversation, its agent started again on the other side. Not while
    /// it works: the container it leaves is removed, and the turn with it.
    func contain(_ record: SessionRecord, into: Bool, size: ContainerSize? = nil,
                 done: @escaping @MainActor (Result<Void, ContainerFailure>) -> Void) {
        guard into != (record.info.container != nil) else { return done(.success(())) }
        guard !record.info.busy else { return done(.failure(ContainerFailure(message: "The agent is working: move it once its turn has ended."))) }
        Task {
            let left = record.info.container
            if into {
                do {
                    record.info.container = try await makeContainer(session: record.info.id, agent: record.info.agent, folder: record.info.cwd,
                                                                    size: size ?? .standard)
                } catch let failure as ContainerFailure {
                    return done(.failure(failure))
                } catch {
                    return done(.failure(ContainerFailure(message: error.localizedDescription)))
                }
            } else {
                record.info.container = nil
            }
            record.placed()
            Self.log("session \(into ? "moved into a container" : "moved out of its container"): \(record.info.title) (\(record.info.id))")
            rebuild(record) {
                if let left { self.removeContainer(left) }
            }
            saveArchive()
            broadcastSessions()
            done(.success(()))
        }
    }

    /// A session's container gone, with its disk (its session ended here,
    /// or left it).
    func removeContainer(_ container: SessionContainer) {
        guard container.socket != nil else {
            return Self.log("the container \(container.id) is Apple's, from before OS Server ran them: `container delete --force \(container.id)` removes it")
        }
        Task {
            await releaseContainer(container.id)
            Self.log("released the container \(container.id)")
        }
    }
}

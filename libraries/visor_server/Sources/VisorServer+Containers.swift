// Sessions whose agents run in Linux containers on this computer (Apple's
// container on a Mac) rather than on it directly. The server makes each
// session's container from Visor's agent image (tools/containers/visor-agent)
// and keeps it running while the session lasts; the agent runs in it under
// a host of its own, as any agent does (`container exec`), so it outlives a
// restart of the server the same way. The container sees the session's
// folder at the same path, the agent's log folder, Xcode read-only, and
// Visor's tools (ContainerTools): the agent works on the same files and
// keeps the same log whichever side it runs on, so a session moves into or
// out of its container by starting its agent again on the other side.
//
//     visor-server containers image <name> | -     the image containers are made from (visor-agent)
//     visor-server containers callback <ws-url> | -  how a container reaches this server

import ClaudeTranscript
import Foundation
import VisorProtocol

extension VisorServer {
    /// The image a container is made from unless another is set: Visor's
    /// own (tools/containers/visor-agent), built on this computer under
    /// this name.
    public nonisolated static let containerImage = "visor-agent"

    /// Whether a session can run in a container here (as last found).
    public var containersAvailable: Bool { containerProblem == nil }

    /// Finds again whether containers can run here, and tells the clients
    /// when that changed.
    public func checkContainers() async {
        var problem: String? = "this system runs no containers"
        if let containers = ServerPlatform.current.containers { problem = await containers.problem() }
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
        guard let container = info.container, let runtime = ServerPlatform.current.containers else { return nil }
        return ContainerPlacement(name: container.id, serverURL: containerServerURL, runtime: runtime)
    }

    /// The name of a session's container.
    static func containerName(session: String) -> String {
        "visor-" + session.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// What a session's container sees of this computer: its folder, at
    /// the same path; the agent's log folder for it, where the agent there
    /// keeps its log; Xcode, read-only (for building Apple apps on Linux);
    /// and Visor's tools.
    static func containerMounts(agent: AgentKind, folder: String, tools: URL) -> [ContainerMount] {
        var mounts = [ContainerMount(source: folder, target: folder)]
        switch agent {
        case .codex:
            // Codex's home in the containers (their own sign-in, one for
            // all: its refreshes go to one file), then the computer's
            // sessions folder in it, where the session's log is kept.
            let sessions = SessionCatalog.codexRoot().appendingPathComponent("sessions", isDirectory: true)
            try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            mounts.append(ContainerMount(source: ContainerSignIns.codexHome.path, target: "/root/.codex"))
            mounts.append(ContainerMount(source: sessions.path, target: "/root/.codex/sessions"))
        case .openrouter:
            // The same for openrouter: its home in the containers (their
            // key), the computer's sessions folder in it.
            let sessions = SessionCatalog.openrouterRoot.appendingPathComponent("sessions", isDirectory: true)
            try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            mounts.append(ContainerMount(source: ContainerSignIns.openrouterHome.path, target: "/root/.openrouter"))
            mounts.append(ContainerMount(source: sessions.path, target: "/root/.openrouter/sessions"))
        case .claude:
            let name = ClaudeSessionFiles.projectDirectoryName(for: folder)
            let project = ClaudeSessionFiles.projectsRoot().appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            mounts.append(ContainerMount(source: project.path, target: "/root/.claude/projects/" + name))
        }
        let xcode = "/Applications/Xcode.app"
        if FileManager.default.fileExists(atPath: xcode) { mounts.append(ContainerMount(source: xcode, target: xcode, readOnly: true)) }
        mounts.append(ContainerMount(source: tools.path, target: ContainerPlacement.toolsFolder, readOnly: true))
        return mounts
    }

    /// Makes the container a session's agent runs in: from the image, with
    /// its mounts, the sign-ins for containers copied into its home, and an
    /// SSH key of its own (for the machines it leases). Removed again when
    /// any of that fails.
    func makeContainer(session: String, agent: AgentKind, folder: String, size: ContainerSize = .standard) async throws -> SessionContainer {
        if containerProblem != nil { await checkContainers() }
        if let containerProblem { throw ContainerFailure(message: "This computer cannot run containers: \(containerProblem).") }
        guard let runtime = ServerPlatform.current.containers, let tools = ContainerTools.folder else {
            throw ContainerFailure(message: "This computer cannot run containers.")
        }
        let resolved = HostFolders.resolve(folder)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isFolder), isFolder.boolValue else {
            throw ContainerFailure(message: "There is no folder \(folder) on this computer.")
        }
        let name = Self.containerName(session: session)
        let image = settings.containerImage.trimmingCharacters(in: .whitespaces).isEmpty ? Self.containerImage : settings.containerImage
        // One left by an earlier attempt goes first (its disk kept, for
        // this one to take up).
        if await runtime.isRunning(name) != nil { try? await runtime.remove(name, keepingDisk: true) }
        // What it is given, within what this computer has.
        let given = Self.fitted(size)
        let spec = ContainerSpec(name: name, image: image, mounts: Self.containerMounts(agent: agent, folder: resolved, tools: tools),
                                 labels: ["visor.session": session], cpus: given.cpus, memory: UInt64(given.memoryBytes),
                                 disk: UInt64(given.diskBytes))
        do {
            try await runtime.run(spec)
        } catch {
            throw ContainerFailure(message: "Could not make the container from \(image): \(error.localizedDescription)")
        }
        do {
            for file in ContainerSignIns.homeFiles() {
                let path = "/root/" + file.path
                let wrote = try await runtime.execute(name, ["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\" && chmod 600 \"$1\"", "sh", path],
                                                      input: file.data)
                guard wrote.status == 0 else { throw ContainerFailure(message: "Could not write \(path) in the container: \(wrote.output)") }
            }
            let key = try await runtime.execute(name, ["sh", "-c", "test -f /root/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -C visor-container -f /root/.ssh/id_ed25519"],
                                                input: nil)
            guard key.status == 0 else { throw ContainerFailure(message: "Could not make the container's SSH key: \(key.output)") }
        } catch {
            try? await runtime.remove(name, keepingDisk: false)
            throw error
        }
        return SessionContainer(id: name, image: image, size: given)
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
    /// Into a container of another size when it is in one already: that
    /// one is made again at the size (`resize`).
    func contain(_ record: SessionRecord, into: Bool, size: ContainerSize? = nil,
                 done: @escaping @MainActor (Result<Void, ContainerFailure>) -> Void) {
        if into, let size, let current = record.info.container, current.size != Self.fitted(size) {
            return resize(record, to: size, done: done)
        }
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

    /// A session's container made again at another size (a container's
    /// processors and memory are fixed when it is made): its agent ended,
    /// the container removed but its disk kept, the new one made, and the
    /// agent started again there. Not while it works. Should the new one
    /// not be made, the session runs on the computer, and says why.
    func resize(_ record: SessionRecord, to size: ContainerSize, done: @escaping @MainActor (Result<Void, ContainerFailure>) -> Void) {
        guard !record.info.busy else { return done(.failure(ContainerFailure(message: "The agent is working: resize its container once its turn has ended."))) }
        guard let runtime = ServerPlatform.current.containers, let old = record.info.container else {
            return done(.failure(ContainerFailure(message: "This computer cannot run containers.")))
        }
        record.held = true
        Task {
            await record.process.end(within: .seconds(3))
            try? await runtime.remove(old.id, keepingDisk: true)
            var failure: ContainerFailure?
            do {
                record.info.container = try await makeContainer(session: record.info.id, agent: record.info.agent, folder: record.info.cwd, size: size)
            } catch {
                record.info.container = nil
                failure = ContainerFailure(message: "The container could not be made again (\((error as? ContainerFailure)?.message ?? error.localizedDescription)): the session runs on the computer now.")
            }
            record.placed()
            Self.log("session's container resized: \(record.info.title) (\(record.info.id))")
            rebuild(record)
            saveArchive()
            broadcastSessions()
            done(failure.map { .failure($0) } ?? .success(()))
        }
    }

    /// A session's container gone, with its disk (its session ended here,
    /// or left it).
    func removeContainer(_ container: SessionContainer) {
        guard let runtime = ServerPlatform.current.containers else { return }
        Task {
            do {
                try await runtime.remove(container.id, keepingDisk: false)
                Self.log("removed the container \(container.id)")
            } catch {
                Self.log("could not remove the container \(container.id): \(error.localizedDescription)")
            }
        }
    }
}

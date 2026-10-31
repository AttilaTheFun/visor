import Foundation

/// A container server (docs/co-tenancy.md): a Visor server running in a
/// container of its own, made and kept here over Apple's `container`. Its
/// home (`/root`: the server's data, the agents' transcripts and sign-ins)
/// and Bazel's output are disks of their own, kept when the container is
/// made again, so its sessions are as they were.
public struct ContainerServer: Sendable {
    public let spec: ServerSpec
    public let folder: URL
    public let container: AppleContainer
    public let secrets: any HostSecrets
    /// The port the server listens on in the container.
    public var serverPort = 7433

    public init(spec: ServerSpec, folder: URL, container: AppleContainer, secrets: any HostSecrets) {
        self.spec = spec
        self.folder = folder
        self.container = container
        self.secrets = secrets
    }

    var name: String { spec.containerName }
    var homeVolume: String { name + "-home" }
    var buildVolume: String { name + "-build" }

    /// What the container is now: running, stopped, or not there.
    public enum ContainerState: String, Sendable { case running, stopped, missing }

    public func state() -> ContainerState {
        guard let had = ContainerHostCommand.inspected(name, container: container) else { return .missing }
        return had.status == "running" ? .running : .stopped
    }

    /// The container's address on this computer's network for containers,
    /// where its server's port is reached from here.
    public func address() -> String? {
        guard let read = container.run(["inspect", name]), read.status == 0,
              let items = (try? JSONSerialization.jsonObject(with: Data(read.output.utf8))) as? [[String: Any]],
              let networks = items.first?["networks"] as? [[String: Any]] else { return nil }
        for network in networks {
            guard let address = network["address"] as? String ?? network["ipv4Address"] as? String else { continue }
            return String(address.split(separator: "/").first ?? Substring(address))
        }
        return nil
    }

    /// The container running, made first where there is none: its disks
    /// (kept from before, or made), this computer's folders, its size, and
    /// Rosetta where the Mac has it. Nil, or what went wrong.
    public func ensureContainer(rosetta: Bool? = nil) -> String? {
        switch state() {
        case .running: return nil
        case .stopped:
            return container.run(["start", name])?.status == 0 ? nil : "\(name) is there but doesn't start"
        case .missing:
            guard FileManager.default.isExecutableFile(atPath: container.tool) else {
                return "Apple's container is not installed (github.com/apple/container)"
            }
            guard container.run(["system", "status"])?.status == 0 else {
                return "Apple's container is not started (container system start)"
            }
            let home = HostRequest.Volume(name: homeVolume, destination: "/root", sizeBytes: 64 << 30)
            let build = HostRequest.Volume(name: buildVolume, destination: "/var/cache/bazel", sizeBytes: spec.diskBytes ?? (128 << 30))
            for volume in [home, build] {
                if let problem = ContainerHostCommand.ensure(volume, container: container) { return problem }
            }
            var request = HostRequest(name: name, image: spec.image)
            request.cpus = spec.cpus
            request.memoryBytes = spec.memoryBytes
            request.mounts = spec.mounts.map { HostRequest.Mount(source: $0.source, destination: $0.destination, readOnly: $0.readOnly) }
            request.volumes = [home, build]
            request.rosetta = true
            request.labels = ["visor.container-server": spec.id]
            guard let made = container.run(ContainerHostCommand.runArguments(request, rosetta: rosetta ?? AppleContainer.hasRosetta)) else {
                return "Apple's container couldn't be started"
            }
            return made.status == 0 ? nil : "Could not make \(name) from \(spec.image): \(made.said)"
        }
    }

    /// The server's password: the one kept, else a new one, kept.
    public func password() throws -> String {
        if let kept = secrets.value("password"), !kept.isEmpty { return kept }
        let made = (0..<4).map { _ in String(UInt32.random(in: 0...UInt32.max), radix: 36) }.joined()
        try secrets.set("password", made)
        return made
    }

    /// The Visor server in the container started, detached there (a host
    /// that restarts leaves it running): its password, given on standard
    /// input rather than its command line, the LAN on (this computer
    /// reaches it over the containers' network), and its codes leading with
    /// `clientAddress`. Nil, or what went wrong.
    public func startServer(clientAddress: String) throws -> String? {
        let password = try password()
        let script = """
            read -r password
            visor-server password "$password" > /dev/null || exit 1
            exec visor-server start --port \(serverPort) --lan on --vpn on --ssh off --address "$1"
            """
        guard let started = container.run(["exec", "--interactive", name, "sh", "-c", script, "sh", clientAddress],
                                          input: Data((password + "\n").utf8)) else {
            return "Apple's container couldn't be started"
        }
        return started.status == 0 ? nil : "The server in \(name) didn't start: \(started.said)"
    }

    /// A file written in the container, its folders made, its mode set.
    func put(_ data: Data, at path: String, mode: String = "600") -> Bool {
        let script = "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\" && chmod \"$2\" \"$1\""
        return container.run(["exec", "--interactive", name, "sh", "-c", script, "sh", path, mode], input: data)?.status == 0
    }

    /// The agents' sign-ins kept here, written into the container: Claude's
    /// token and OpenRouter's key in its server's agent files, Codex's file
    /// in its home. One taken away is taken out there too. Nil, or what
    /// went wrong.
    public func applyCredentials() -> String? {
        let data = "/root/.local/share/visor/agents/"
        let files: [(path: String, contents: String?)] = [
            (data + "claude.env", secrets.value("claudeToken").map { "CLAUDE_CODE_OAUTH_TOKEN=\($0)\n" }),
            (data + "openrouter.env", secrets.value("openrouterKey").map { "OPENROUTER_API_KEY=\($0)\n" }),
            ("/root/.codex/auth.json", secrets.value("codexAuth").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }),
        ]
        for file in files {
            if let contents = file.contents {
                guard put(Data(contents.utf8), at: file.path) else { return "Could not write \(file.path) in \(name)" }
            } else {
                _ = container.run(["exec", name, "rm", "-f", file.path])
            }
        }
        return nil
    }

    /// Whether the container's network works: its address on a network
    /// this computer still has (the containers' network made again under a
    /// running container leaves it on one that is gone, where nothing
    /// reaches it), and from in it, names resolved and HTTPS reached.
    public func networkCheck(local: [HostAddresses.Address] = HostAddresses.all()) -> ServerState.Network {
        guard let address = address() else { return .init(ok: false, detail: "it has no address") }
        let subnet = address.split(separator: ".").prefix(3).joined(separator: ".") + "."
        guard local.contains(where: { $0.address.hasPrefix(subnet) }) else {
            return .init(ok: false, detail: "its address \(address) is on no network this computer has")
        }
        let checked = ContainerHostCommand.network([name], container: container)
        return .init(ok: checked.json["ok"] as? Bool ?? false, detail: checked.json["detail"] as? String ?? "it couldn't be asked")
    }

    public func stop() -> Bool { container.run(["stop", name])?.status == 0 }

    /// The container gone; with `data`, its disks too, and with them its
    /// sessions.
    public func remove(data: Bool) {
        _ = container.run(["delete", "--force", name])
        if data {
            for volume in [homeVolume, buildVolume] { _ = container.run(["volume", "delete", volume]) }
        }
    }
}

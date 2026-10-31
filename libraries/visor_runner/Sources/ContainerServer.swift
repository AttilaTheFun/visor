import CVisorPOSIX
import Foundation

/// A container server's container and the Visor server in it
/// (docs/co-tenancy.md), made and kept by the Runner with Apple's
/// `container`. Its home (`/root`: the server's data, the agents'
/// transcripts and sign-ins) and Bazel's output are volumes of their own,
/// kept when the container is made again, so its sessions are as they were.
public struct ContainerServer: Sendable {
    public let spec: ContainerServerSpec
    public let cli: ContainerCLI
    /// The port the server listens on in the container.
    public var serverPort = 7433
    /// The label the Runner's containers carry their server's id in.
    public static let label = "visor.container-server"

    public init(spec: ContainerServerSpec, cli: ContainerCLI) {
        self.spec = spec
        self.cli = cli
    }

    public var name: String { spec.containerName }
    var homeVolume: String { name + "-home" }
    var buildVolume: String { name + "-build" }

    /// Where the server's port is published on this computer: every
    /// interface when the LAN or a VPN reaches it, else loopback alone.
    var publishedHost: String { spec.listen.lan || spec.listen.vpn ? "0.0.0.0" : "127.0.0.1" }

    /// The container as it is now; nil when there is none.
    public func container() -> ContainerCLI.Container? { cli.inspect(name) }

    /// `container run`'s arguments: its volumes, this computer's folders,
    /// its label, its size, its server's port published, Rosetta where the
    /// Mac has it; the main process only waits.
    func runArguments(rosetta: Bool) -> [String] {
        var arguments = ["run", "--detach", "--name", name,
                         "--volume", "\(homeVolume):/root", "--volume", "\(buildVolume):/var/cache/bazel"]
        for mount in spec.mounts {
            arguments += ["--mount", "type=bind,source=\(mount.source),target=\(mount.destination)" + (mount.readOnly == true ? ",readonly" : "")]
        }
        arguments += ["--label", "\(Self.label)=\(spec.id)"]
        if let cpus = spec.cpus { arguments += ["--cpus", String(cpus)] }
        if let memory = spec.memoryBytes { arguments += ["--memory", "\(max(memory / 1_048_576, 512))M"] }
        arguments += ["--publish", "\(publishedHost):\(spec.listen.port):\(serverPort)"]
        if rosetta { arguments += ["--rosetta"] }
        return arguments + [spec.image, "sleep", "infinity"]
    }

    /// The container running: made where there is none (its volumes kept
    /// from before, or made), started where it has stopped. Nil, or what
    /// went wrong.
    public func ensureRunning(rosetta: Bool = FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")) -> String? {
        if let had = container() {
            if had.status == "running" { return nil }
            return cli.run(["start", name])?.status == 0 ? nil : "\(name) is there but doesn't start"
        }
        guard cli.installed else { return "Apple's container is not installed (github.com/apple/container)" }
        guard cli.run(["system", "status"])?.status == 0 else { return "Apple's container is not started (container system start)" }
        for (volume, bytes) in [(homeVolume, Int64(64) << 30), (buildVolume, spec.diskBytes ?? (Int64(128) << 30))] {
            if cli.run(["volume", "inspect", volume])?.status == 0 { continue }
            guard cli.run(["volume", "create", "-s", "\(bytes / 1_048_576)M", volume])?.status == 0 else {
                return "Could not make the volume \(volume)"
            }
        }
        guard let made = cli.run(runArguments(rosetta: rosetta)) else { return "Apple's container couldn't be started" }
        return made.status == 0 ? nil : "Could not make \(name) from \(spec.image): \(made.said)"
    }

    /// Whether the server takes connections at its published port now.
    public func answering() -> Bool {
        let connection = visor_connect_tcp("127.0.0.1", UInt16(spec.listen.port))
        guard connection >= 0 else { return false }
        close(connection)
        return true
    }

    /// The server started in the container, detached there (the Runner's
    /// quitting leaves it, and its agents, running): its password given on
    /// standard input, never on a command line; its codes leading with
    /// `clientAddress`. Nil, or what went wrong.
    public func startServer(password: String, clientAddress: String) -> String? {
        let script = """
            read -r password
            visor-server password "$password" > /dev/null || exit 1
            exec visor-server start --port \(serverPort) --lan on --vpn on --ssh off --address "$1"
            """
        guard let started = cli.run(["exec", "--interactive", name, "sh", "-c", script, "sh", clientAddress],
                                    input: Data((password + "\n").utf8)) else {
            return "Apple's container couldn't be started"
        }
        return started.status == 0 ? nil : "The server in \(name) didn't start: \(started.said)"
    }

    /// A file written in the container, its folders made, its mode set.
    func put(_ data: Data, at path: String, mode: String = "600") -> Bool {
        let script = "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\" && chmod \"$2\" \"$1\""
        return cli.run(["exec", "--interactive", name, "sh", "-c", script, "sh", path, mode], input: data)?.status == 0
    }

    /// The agents' sign-ins written into the container: Claude's token and
    /// OpenRouter's key in its server's agent files, Codex's file in its
    /// home. One that is nil is taken out. Nil, or what went wrong.
    public func writeSignIns(_ signIns: SignIns) -> String? {
        let data = "/root/.local/share/visor/agents/"
        let files: [(path: String, contents: String?)] = [
            (data + "claude.env", signIns.claudeToken.map { "CLAUDE_CODE_OAUTH_TOKEN=\($0)\n" }),
            (data + "openrouter.env", signIns.openrouterKey.map { "OPENROUTER_API_KEY=\($0)\n" }),
            ("/root/.codex/auth.json", signIns.codexAuth.map { String(decoding: $0, as: UTF8.self) }),
        ]
        for file in files {
            if let contents = file.contents {
                guard put(Data(contents.utf8), at: file.path) else { return "Could not write \(file.path) in \(name)" }
            } else {
                _ = cli.run(["exec", name, "rm", "-f", file.path])
            }
        }
        return nil
    }

    /// The agents' sign-ins a container server is given.
    public struct SignIns: Equatable, Sendable {
        public var claudeToken: String?
        public var openrouterKey: String?
        /// The Mac's `~/.codex/auth.json`.
        public var codexAuth: Data?

        public init(claudeToken: String? = nil, openrouterKey: String? = nil, codexAuth: Data? = nil) {
            self.claudeToken = claudeToken
            self.openrouterKey = openrouterKey
            self.codexAuth = codexAuth
        }
    }

    /// This computer's address as the container sees it: its default
    /// route's gateway (from /proc/net/route, the address in hex, its bytes
    /// in the kernel's order).
    public func gateway() -> String? {
        let script = "awk '$2 == \"00000000\" { print $3; exit }' /proc/net/route"
        guard let read = cli.run(["exec", name, "sh", "-c", script]), read.status == 0,
              let value = UInt32(read.output.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }
        return [value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, value >> 24].map(String.init).joined(separator: ".")
    }

    /// A REST call to the server, made in the container with its password
    /// (in a file of the container's for the call, never on a command
    /// line): its answer's body, or nil.
    func call(_ method: String, _ path: String, password: String, body: Data? = nil) -> Answer? {
        let folder = "/root/.visor-runner/"
        guard put(Data("Authorization: Bearer \(password)\n".utf8), at: folder + "auth") else { return nil }
        var script = "curl -s -m 10 -X \(method) -H @\(folder)auth"
        if let body {
            guard put(body, at: folder + "body.json") else { return nil }
            script += " -H 'Content-Type: application/json' --data-binary @\(folder)body.json"
        }
        script += " http://127.0.0.1:\(serverPort)/api/\(path); rm -f \(folder)auth \(folder)body.json"
        return cli.run(["exec", name, "sh", "-c", script]).map { Answer(status: $0.status, output: $0.output) }
    }

    /// A REST call's answer: curl's status, and the body.
    struct Answer {
        var status: Int32
        var output: String

        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] }
    }

    /// The server's MCP servers set to the Runner's proxy (its `PUT
    /// /api/mcp`): each endpoint at `proxy` (`http://<gateway>:<port>`),
    /// `/mcp/<name>`, with its headers that aren't secret and this server's
    /// token for the proxy as a secret header. Nil, or what went wrong.
    public func setMCP(_ endpoints: [MCPProxy.Endpoint], proxy: String, token: String, password: String) -> String? {
        let listed: [[String: Any]] = endpoints.map { endpoint in
            let headers = endpoint.headers.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value, "secret": false] as [String: Any] }
            return ["name": endpoint.name, "url": "\(proxy)/mcp/\(endpoint.name)",
                    "headers": headers + [["name": MCPProxy.tokenHeader, "value": token, "secret": true]]]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["endpoints": listed]) else { return "The MCP servers couldn't be written" }
        guard let answer = call("PUT", "mcp", password: password, body: body), answer.status == 0, answer.json != nil else {
            return "The server in \(name) didn't take its MCP servers"
        }
        return nil
    }

    /// What the server says of itself (`/api/hello`'s version) and its
    /// connection code, asked in the container.
    public func hello(password: String) -> (version: String?, code: String?)? {
        guard let hello = call("GET", "hello", password: password)?.json else { return nil }
        return (hello["version"] as? String, call("GET", "code", password: password)?.json?["text"] as? String)
    }

    /// Whether the container's network works: its address on a network
    /// this computer still has (the containers' network made again under a
    /// running container leaves it on one that is gone, where nothing
    /// reaches it), and from in it, names resolved and HTTPS reached.
    public func networkCheck(local: [HostAddresses.Address] = HostAddresses.all()) -> ContainerServerState.Network {
        guard let address = container()?.address else { return .init(ok: false, detail: "it has no address") }
        let subnet = address.split(separator: ".").prefix(3).joined(separator: ".") + "."
        guard local.contains(where: { $0.address.hasPrefix(subnet) }) else {
            return .init(ok: false, detail: "its address \(address) is on no network this computer has")
        }
        let probe = "github.com"
        let script = "getent hosts \(probe) > /dev/null && echo dns; curl -s -o /dev/null --max-time 8 https://\(probe) && echo reach"
        guard let checked = cli.run(["exec", name, "sh", "-c", script]) else { return .init(ok: false, detail: "it couldn't be asked") }
        let dns = checked.output.contains("dns"), reach = checked.output.contains("reach")
        if dns && reach { return .init(ok: true, detail: "resolves and reaches \(probe)") }
        return .init(ok: false, detail: dns ? "resolves, but reaches nothing (\(probe))" : "resolves no names (\(probe))")
    }

    public func stop() -> Bool { cli.run(["stop", name])?.status == 0 }

    /// The container gone, its volumes kept: made again, it is as it was.
    public func removeContainer() {
        _ = cli.run(["delete", "--force", name])
    }

    /// The container gone, and its volumes with it, and with them its
    /// sessions.
    public func removeWithVolumes() {
        removeContainer()
        for volume in [homeVolume, buildVolume] { _ = cli.run(["volume", "delete", volume]) }
    }
}

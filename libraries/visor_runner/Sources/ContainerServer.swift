import CVisorPOSIX
import Foundation

/// A container server's container and the Visor server in it
/// (docs/co-tenancy.md), made and kept by the Runner through its container
/// backend. Its home (`/root`: the server's data, the agents' transcripts
/// and sign-ins) and Bazel's output are volumes of their own, kept when the
/// container is made again, so its sessions are as they were. Its server
/// listens in plain HTTP on the container's address, which only this
/// computer reaches: clients reach it through the Runner's proxy.
public struct ContainerServer: Sendable {
    public let spec: ContainerServerSpec
    public let backend: any ContainerBackend
    /// The port the server listens on in the container.
    public var serverPort = 7433
    /// The label the Runner's containers carry their server's id in.
    public static let label = "visor.container-server"

    public init(spec: ContainerServerSpec, backend: any ContainerBackend) {
        self.spec = spec
        self.backend = backend
    }

    public var name: String { spec.containerName }
    var homeVolume: String { name + "-home" }
    var buildVolume: String { name + "-build" }

    /// The container as it is now; nil when there is none.
    public func container() -> ContainerInfo? { backend.container(name) }

    /// What it is made from: its image, its volumes, this computer's
    /// folders, its label, its size, Rosetta where the Mac has it.
    func request(rosetta: Bool) -> ContainerRequest {
        var request = ContainerRequest(name: name, image: spec.image)
        request.cpus = spec.cpus
        request.memoryBytes = spec.memoryBytes
        request.volumes = [.init(name: homeVolume, destination: "/root", sizeBytes: Int64(64) << 30),
                           .init(name: buildVolume, destination: "/var/cache/bazel", sizeBytes: spec.diskBytes ?? (Int64(128) << 30))]
        request.mounts = spec.mounts.map { .init(source: $0.source, destination: $0.destination, readOnly: $0.readOnly ?? false) }
        request.labels = [Self.label: spec.id]
        request.rosetta = rosetta
        return request
    }

    /// The container running: made where there is none (its volumes kept
    /// from before, or made), started where it has stopped. Nil, or what
    /// went wrong.
    public func ensureRunning(rosetta: Bool = FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")) -> String? {
        if let had = container() {
            return had.running ? nil : backend.start(name).map { "\(name) is there but doesn't start: \($0)" }
        }
        if let unavailable = backend.unavailable() { return unavailable }
        return backend.create(request(rosetta: rosetta)).map { "Could not make \(name) from \(spec.image): \($0)" }
    }

    /// Where the server is reached from this computer: the container's
    /// address and the server's port.
    public func upstream() -> (host: String, port: UInt16)? {
        container()?.address.map { ($0, UInt16(serverPort)) }
    }

    /// Whether the server takes connections now.
    public func answering() -> Bool {
        guard let upstream = upstream() else { return false }
        let connection = visor_connect_tcp(upstream.host, upstream.port)
        guard connection >= 0 else { return false }
        close(connection)
        return true
    }

    /// A shell script run in the container with `arguments` ($1…).
    func shell(_ script: String, _ arguments: [String] = [], input: Data? = nil) -> ContainerExec? {
        backend.exec(name, ["sh", "-c", script, "sh"] + arguments, input: input)
    }

    /// The server started in the container, detached there (the Runner's
    /// quitting leaves it, and its agents, running): its password given on
    /// standard input, never on a command line; its codes leading with
    /// `clientAddress`. It listens on the container's own address, where
    /// only this computer reaches it. Nil, or what went wrong.
    public func startServer(password: String, clientAddress: String) -> String? {
        let script = """
            read -r password
            visor-server password "$password" > /dev/null || exit 1
            exec visor-server start --port \(serverPort) --lan on --vpn on --ssh off --address "$1"
            """
        guard let started = shell(script, [clientAddress], input: Data((password + "\n").utf8)) else {
            return "Nothing could be run in \(name)"
        }
        return started.status == 0 ? nil : "The server in \(name) didn't start: \(started.said)"
    }

    /// A file written in the container, its folders made, its mode set.
    func put(_ data: Data, at path: String, mode: String = "600") -> Bool {
        shell("mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\" && chmod \"$2\" \"$1\"", [path, mode], input: data)?.status == 0
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
                _ = backend.exec(name, ["rm", "-f", file.path], input: nil)
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
        guard let read = shell("awk '$2 == \"00000000\" { print $3; exit }' /proc/net/route"), read.status == 0,
              let value = UInt32(read.output.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }
        return [value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, value >> 24].map(String.init).joined(separator: ".")
    }

    /// A REST call to the server, made in the container with its password
    /// (in a file of the container's for the call, never on a command
    /// line): curl's status and the answer's body, or nil.
    func call(_ method: String, _ path: String, password: String, body: Data? = nil) -> ContainerExec? {
        let folder = "/root/.visor-runner/"
        guard put(Data("Authorization: Bearer \(password)\n".utf8), at: folder + "auth") else { return nil }
        var script = "curl -s -m 10 -X \(method) -H @\(folder)auth"
        if let body {
            guard put(body, at: folder + "body.json") else { return nil }
            script += " -H 'Content-Type: application/json' --data-binary @\(folder)body.json"
        }
        script += " http://127.0.0.1:\(serverPort)/api/\(path); rm -f \(folder)auth \(folder)body.json"
        return shell(script)
    }

    /// A REST answer's JSON object.
    static func json(_ answer: ContainerExec?) -> [String: Any]? {
        guard let answer, answer.status == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(answer.output.utf8))) as? [String: Any]
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
        guard Self.json(call("PUT", "mcp", password: password, body: body)) != nil else {
            return "The server in \(name) didn't take its MCP servers"
        }
        return nil
    }

    /// What the server says of itself (`/api/hello`'s version) and its
    /// connection code, asked in the container.
    public func hello(password: String) -> (version: String?, code: String?)? {
        guard let hello = Self.json(call("GET", "hello", password: password)) else { return nil }
        return (hello["version"] as? String, Self.json(call("GET", "code", password: password))?["text"] as? String)
    }

    /// Whether the container's network works: its address on a network
    /// this computer still has (a network made again under a running
    /// container leaves it on one that is gone, where nothing reaches it),
    /// and from in it, names resolved and HTTPS reached.
    public func networkCheck(local: [HostAddresses.Address] = HostAddresses.all()) -> ContainerServerState.Network {
        guard let address = container()?.address else { return .init(ok: false, detail: "it has no address") }
        let subnet = address.split(separator: ".").prefix(3).joined(separator: ".") + "."
        guard local.contains(where: { $0.address.hasPrefix(subnet) }) else {
            return .init(ok: false, detail: "its address \(address) is on no network this computer has")
        }
        let probe = "github.com"
        guard let checked = shell("getent hosts \(probe) > /dev/null && echo dns; curl -s -o /dev/null --max-time 8 https://\(probe) && echo reach") else {
            return .init(ok: false, detail: "it couldn't be asked")
        }
        let dns = checked.output.contains("dns"), reach = checked.output.contains("reach")
        if dns && reach { return .init(ok: true, detail: "resolves and reaches \(probe)") }
        return .init(ok: false, detail: dns ? "resolves, but reaches nothing (\(probe))" : "resolves no names (\(probe))")
    }

    public func stop() -> Bool { backend.stop(name) == nil }

    /// The container gone, its volumes kept: made again, it is as it was.
    public func removeContainer() {
        backend.remove(name, volumes: [])
    }

    /// The container gone, and its volumes with it, and with them its
    /// sessions.
    public func removeWithVolumes() {
        backend.remove(name, volumes: [homeVolume, buildVolume])
    }
}

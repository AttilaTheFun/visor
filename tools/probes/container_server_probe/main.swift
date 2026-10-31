import CVisorPOSIX
import Foundation
import Synchronization
import VisorRunner

// container-server-probe <image> [--port=7488] [--mcp-port=7489] [--lan] [--keep]
//
// One container server made with Apple's `container` in a folder of its own
// (not the menu bar app's), then checked: its server ready and its code
// leading with the published address; that port reached here; an MCP call
// made from inside the container through the probe's proxy at its gateway,
// the secret header added on the way; picked up by a second set of
// container servers, as after the Runner restarts, without being made
// again. Removed after (its container, volumes and folder), unless --keep.
// Exits 1 at the first check that fails.

let arguments = CommandLine.arguments.dropFirst()
guard let image = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("container-server-probe <image> [--port=7488] [--mcp-port=7489] [--lan] [--keep]")
    exit(2)
}
func option(_ name: String, _ fallback: Int) -> Int {
    arguments.first { $0.hasPrefix("--\(name)=") }.flatMap { Int($0.split(separator: "=").last ?? "") } ?? fallback
}
let port = option("port", 7488), mcpPort = option("mcp-port", 7489)
let lan = arguments.contains("--lan"), keep = arguments.contains("--keep")

/// The probe's secrets, in memory.
private final class ProbeSecrets: RunnerSecrets {
    private let values = Mutex<[String: String]>([:])
    func value(_ name: String) -> String? { values.withLock { $0[name] } }
    func set(_ name: String, _ value: String?) { values.withLock { $0[name] = value } }
}

func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { exit(1) }
}

// An MCP endpoint of the probe's own on loopback: it answers with the
// Authorization header it was given, so the probe sees the secret added.
let echoPort = UInt16(option("echo-port", 7490))
let echo = visor_listen(echoPort, 0)
check(echo >= 0, "the probe's MCP endpoint listens at 127.0.0.1:\(echoPort)")
Thread.detachNewThread {
    while true {
        let connection = visor_accept(echo)
        if connection < 0 { return }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            request.append(contentsOf: buffer[0..<count])
        }
        let authorization = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("authorization:") } ?? "none"
        let body = "{\"saw\":\"\(authorization)\"}"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        _ = Array(response.utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        close(connection)
    }
}

let folders = FileManager.default.temporaryDirectory.appendingPathComponent("container-server-probe-\(getpid())", isDirectory: true)
private let secrets = ProbeSecrets()
let endpoints = [MCPProxy.Endpoint(name: "echo", url: "http://127.0.0.1:\(echoPort)/mcp", secretHeaders: ["Authorization"])]
func servers() -> ContainerServers {
    ContainerServers(folders: folders, secrets: secrets, mcpPort: mcpPort, endpoints: { endpoints }, signIns: { .init(claudeToken: "probe") },
                     patience: .seconds(120), log: { print("      \($0)") })
}
let first = servers()
let proxy = MCPProxy(port: UInt16(mcpPort), endpoints: { endpoints }, admits: { first.admits($0) }) { _, header in
    header == "Authorization" ? "Bearer probe-secret" : nil
}
check(proxy != nil, "the probe's MCP proxy listens at port \(mcpPort), every interface")
proxy?.start()

var spec = ContainerServerSpec(id: "probe-\(getpid())", name: "Probe", image: image)
spec.listen = .init(port: port, lan: lan, vpn: false)
print("      making \(spec.containerName) from \(image) (published at \(lan ? "0.0.0.0" : "127.0.0.1"):\(port))")
let problem = first.make(spec)
check(problem == nil, "made and its server started\(problem.map { ": \($0)" } ?? "")")
let state = first.state(spec.id)
check(state?.state == "ready", "ready (\(state?.server?.version ?? "no version"))")
check(state?.code?.isEmpty == false, "its connection code: \(state?.address ?? "no address")")
let connection = visor_connect_tcp("127.0.0.1", UInt16(port))
check(connection >= 0, "its published port takes a connection at 127.0.0.1:\(port)")
close(connection)
if lan, let address = HostAddresses.all().first(where: { HostAddresses.isLAN($0.address) && !$0.interface.hasPrefix("bridge") }) {
    let reached = visor_connect_tcp(address.address, UInt16(port))
    check(reached >= 0, "and at this Mac's LAN address \(address.address):\(port)")
    close(reached)
}

// From inside the container: the MCP server as its server was given it.
let cli = ContainerCLI()
let token = secrets.value("container-server \(spec.id) mcpToken") ?? ""
let script = "gw=$(awk '$2 == \"00000000\" { print $3; exit }' /proc/net/route); "
    + "ip=$(printf '%d.%d.%d.%d' 0x${gw:6:2} 0x${gw:4:2} 0x${gw:2:2} 0x${gw:0:2}); "
    + "curl -s -m 10 -X POST -H \"\(MCPProxy.tokenHeader): $1\" --data '{}' http://$ip:\(mcpPort)/mcp/echo"
let called = cli.run(["exec", spec.containerName, "bash", "-c", script, "bash", token])
check(called?.output.contains("Bearer probe-secret") == true,
      "an MCP call from inside goes through the proxy at its gateway, the secret added (\(called?.said ?? "no answer"))")

// A second set, as after the Runner restarts: picked up, not made again.
let again = servers().pickUp()
check(again.isEmpty, "picked up again\(again.values.first.map { ": \($0)" } ?? "")")
check(servers().state(spec.id)?.state == "ready", "still ready, the same container")

if keep {
    print("      kept: \(spec.containerName), folder \(folders.path)")
} else {
    first.remove(spec.id)
    check(cli.inspect(spec.containerName) == nil, "removed, with its volumes")
}
proxy?.stop()
print("all checks passed")

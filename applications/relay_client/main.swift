// relay-client run [--relay <socket>] [--port <n>] [--no-setup] -- <command…>
// relay-client check <host>:<port> [--send <text>]
//
// The container's helper (Visor's docs/server-proxy.md, "Containers: no
// network"): the container has no network, only the relay's socket to
// agent-proxy. It sets the network up over netlink (ContainerNetwork: the
// default route through loopback, one nftables redirect, resolv.conf), answers DNS on 127.0.0.1:53
// (ClientResolver), relays every TCP connection by name
// (RedirectListener), then runs the command, passing it the signals it
// gets, and ends with its status. Run as root in the container's own
// network namespace.

import Foundation
import VisorAgentProxy
import VisorRelayClient

let usage = """
    Usage: relay-client run [--relay <socket>] [--port <n>] [--no-setup] -- <command…>
           relay-client check <host>:<port> [--send <text>]

      --relay     The relay's socket (/run/agent-proxy/relay.sock; MultiPass's
                  /run/multipass/relay.sock where only that is there).
      --port      The redirect listener's port on 127.0.0.1 (15001).
      --no-setup  Leave the network as it is: no route, rule or
                  resolv.conf (they were set up already).

    check resolves a name and connects to it as any program in the container
    would (through the relay, once run has set things up), sending --send's
    text and showing what comes back. Its status is 0 if all went through.
    """

let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("relay-client: \($0)\n".utf8)) }

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "check" {
    let target = arguments.count >= 2 ? arguments[1] : ""
    let send = arguments.count == 4 && arguments[2] == "--send" ? arguments[3] : nil
    guard arguments.count == 2 || send != nil, let (ok, lines) = ConnectionCheck.run(target, send: send) else {
        print(usage)
        exit(2)
    }
    for line in lines { print(line) }
    exit(ok ? 0 : 1)
}
guard arguments.first == "run" else {
    print(usage)
    exit(arguments.first == "help" || arguments.first == "--help" || arguments.first == "-h" ? 0 : 2)
}
arguments.removeFirst()
var relayPath = RelayDialer.defaultPath
var port: UInt16 = 15001
var setUp = true
var command: [String] = []
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--relay" where !arguments.isEmpty: relayPath = arguments.removeFirst()
    case "--port" where !arguments.isEmpty:
        guard let given = UInt16(arguments.removeFirst()), given > 0 else {
            log("--port: a port from 1 to 65535")
            exit(2)
        }
        port = given
    case "--no-setup": setUp = false
    case "--":
        command = arguments
        arguments = []
    default:
        log("\(argument)?\n\n\(usage)")
        exit(2)
    }
}
guard !command.isEmpty else {
    log("no command to run\n\n\(usage)")
    exit(2)
}

// The network first: in a new namespace loopback is down, with no
// 127.0.0.1 to listen on until it is up.
if setUp, let problem = ContainerNetwork.setUp(listenerPort: port) {
    log("setting up the network: \(problem)")
    exit(71)
}
let relay = RelayDialer(path: relayPath)
let addresses = FakeAddresses()
guard let listener = RedirectListener(port: port, addresses: addresses, relay: relay, log: log) else {
    log("port \(port) on 127.0.0.1 can't be had")
    exit(71)
}
listener.start()
let dns: DNSServer
do {
    dns = try await DNSServer(hosts: ["127.0.0.1"], port: 53, forwarder: ClientResolver(addresses: addresses, relay: relay))
} catch {
    log("127.0.0.1:53 can't be had for DNS: \(error)")
    exit(71)
}
Task { await dns.run() }

// The command, found on PATH as a shell would, with this process's
// standard input, output and error, and its process group (Spawn: not
// Foundation's Process).
guard let workload = Spawn.start(command) else {
    log("\(command[0]): not found")
    exit(127)
}
let forwarded = [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { kill(workload, number) }
    source.resume()
    return source
}
let status = await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
    Thread.detachNewThread { done.resume(returning: Spawn.wait(workload)) }
}
for source in forwarded { source.cancel() }
listener.stop()
exit(status)

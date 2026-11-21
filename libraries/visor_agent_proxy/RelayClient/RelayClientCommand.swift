// relay-client run [--relay <socket>] [--port <n>] [--forward <port>=<socket>]… [--no-setup] -- <command…>
// relay-client check <host>:<port> [--send <text>]
// relay-client check [--relay <socket>]
//
// The container's helper (Visor's docs/server-proxy.md, "Containers: no
// network"): the container has no network, only the relay's socket to
// agent-proxy. It sets the network up over netlink (ContainerNetwork: the
// default route through loopback, one nftables redirect, resolv.conf), answers DNS on 127.0.0.1:53
// (ClientResolver), relays every TCP connection by name
// (RedirectListener), forwards each `--forward` port on 127.0.0.1 to its
// Unix socket (LoopbackForward: Visor's driver, never through the relay),
// then runs the command, passing it the signals it gets, and ends with its
// status. Run as root in the container's own
// network namespace.
//
// The program that ships is visor-server run by this name (relay-client, a
// link to it: tools/linux_programs.sh), so the Swift runtime, Foundation
// and its ICU data, NIO and BoringSSL are carried once in the Mac app;
// applications/relay_client is the same command on its own, for Bazel.

import Foundation
import VisorAgentProxy

/// relay-client's command line.
public enum RelayClientCommand {
    static let usage = """
        Usage: relay-client run [--relay <socket>] [--port <n>] [--forward <port>=<socket>]… [--no-setup] -- <command…>
               relay-client check <host>:<port> [--send <text>]
               relay-client check [--relay <socket>]

          --relay     The relay's socket (/run/agent-proxy/relay.sock; MultiPass's
                      /run/multipass/relay.sock where only that is there).
          --port      The redirect listener's port on 127.0.0.1 (15001).
          --forward   A port on 127.0.0.1 whose connections go to a Unix socket, never
                      through the relay (7434=/run/visor/driver.sock: Visor's driver).
                      Loopback is never redirected. Any number of them.
          --no-setup  Leave the network as it is: no route, rule or
                      resolv.conf (they were set up already).

        check resolves a name and connects to it as any program in the container
        would (through the relay, once run has set things up), sending --send's
        text and showing what comes back. Its status is 0 if all went through.
        With no <host>:<port>, check asks agent-proxy's health over the relay's
        socket itself (nothing resolved, nothing on the internet): 0 when
        agent-proxy answers.
        """

    static let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("relay-client: \($0)\n".utf8)) }

    /// Runs the command line (`commandLine`, the program's name first) and
    /// answers the status to exit with.
    public static func main(_ commandLine: [String]) async -> Int32 {
        var arguments = Array(commandLine.dropFirst())
        if arguments.first == "check", arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--relay") {
            let (ok, line) = RelayHealthCheck.run(path: arguments.count == 3 ? arguments[2] : RelayDialer.defaultPath)
            print(line)
            return ok ? 0 : 1
        }
        if arguments.first == "check" {
            let target = arguments.count >= 2 ? arguments[1] : ""
            let send = arguments.count == 4 && arguments[2] == "--send" ? arguments[3] : nil
            guard arguments.count == 2 || send != nil, let (ok, lines) = ConnectionCheck.run(target, send: send) else {
                print(usage)
                return 2
            }
            for line in lines { print(line) }
            return ok ? 0 : 1
        }
        guard arguments.first == "run" else {
            print(usage)
            return arguments.first == "help" || arguments.first == "--help" || arguments.first == "-h" ? 0 : 2
        }
        arguments.removeFirst()
        var relayPath = RelayDialer.defaultPath
        var port: UInt16 = 15001
        var setUp = true
        var forwards: [LoopbackForward.Spec] = []
        var command: [String] = []
        while let argument = arguments.first {
            arguments.removeFirst()
            switch argument {
            case "--relay" where !arguments.isEmpty: relayPath = arguments.removeFirst()
            case "--port" where !arguments.isEmpty:
                guard let given = UInt16(arguments.removeFirst()), given > 0 else {
                    log("--port: a port from 1 to 65535")
                    return 2
                }
                port = given
            case "--forward" where !arguments.isEmpty:
                let given = arguments.removeFirst()
                guard let spec = LoopbackForward.Spec(given) else {
                    log("--forward \(given): <port>=<socket>, a port from 1 to 65535 and the socket's absolute path")
                    return 2
                }
                forwards.append(spec)
            case "--no-setup": setUp = false
            case "--":
                command = arguments
                arguments = []
            default:
                log("\(argument)?\n\n\(usage)")
                return 2
            }
        }
        guard !command.isEmpty else {
            log("no command to run\n\n\(usage)")
            return 2
        }
        if let taken = Self.clash(forwards, listenerPort: port) {
            log("--forward \(taken): that port is taken already (the redirect listener's, DNS's, or another forward's)")
            return 2
        }

        // The network first: in a new namespace loopback is down, with no
        // 127.0.0.1 to listen on until it is up.
        if setUp, let problem = ContainerNetwork.setUp(listenerPort: port) {
            log("setting up the network: \(problem)")
            return 71
        }
        let relay = RelayDialer(path: relayPath)
        let addresses = FakeAddresses()
        guard let listener = RedirectListener(port: port, addresses: addresses, relay: relay, log: log) else {
            log("port \(port) on 127.0.0.1 can't be had")
            return 71
        }
        listener.start()
        var forwarding: [LoopbackForward] = []
        for spec in forwards {
            guard let forward = LoopbackForward(spec, log: log) else {
                log("port \(spec.port) on 127.0.0.1 can't be had for --forward")
                return 71
            }
            forward.start()
            forwarding.append(forward)
            log("forwarding \(spec)")
        }
        let dns: DNSServer
        do {
            dns = try await DNSServer(hosts: ["127.0.0.1"], port: 53, forwarder: ClientResolver(addresses: addresses, relay: relay))
        } catch {
            log("127.0.0.1:53 can't be had for DNS: \(error)")
            return 71
        }
        Task { await dns.run() }

        // The command, found on PATH as a shell would, with this process's
        // standard input, output and error, and its process group (Spawn: not
        // Foundation's Process).
        guard let workload = Spawn.start(command) else {
            log("\(command[0]): not found")
            return 127
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
        for forward in forwarding { forward.stop() }
        return status
    }

    /// The first forward whose port is the redirect listener's, DNS's (53),
    /// or an earlier forward's; nil when none is.
    static func clash(_ forwards: [LoopbackForward.Spec], listenerPort: UInt16) -> UInt16? {
        var taken: Set<UInt16> = [listenerPort, 53]
        for spec in forwards {
            if !taken.insert(spec.port).inserted { return spec.port }
        }
        return nil
    }
}

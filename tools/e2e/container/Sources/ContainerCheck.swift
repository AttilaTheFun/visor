// The Sessions container end to end (docs/containers.md), on bare metal:
//
// 1. This Mac can run it (macOS 26 or later, Apple silicon, Virtualization).
// 2. A throwaway data folder (/tmp/visor-e2e-container-<id>): agent-proxy's
//    relay listener started in this process on a free loopback port (never
//    7499, nor the real server's), its relay token made in memory.
// 3. The engine, on that folder: the assets fetched and checked, the
//    programs staged (the link check), the root filesystem cloned, the
//    boot with no network, and `relay-client check` through the relay:
//    running.
// 4. In the guest: `relay-client check` again, `uname -a`, a file written to
//    <Sessions>/.visor-e2e-container-<id> from each side and read from the
//    other (and owned by this user on the host), and no LAN: only `lo` in
//    /sys/class/net, and a connection to this Mac's own address and to a
//    private address refused by agent-proxy.
// 5. The driver link: agent-proxy stopped first, so nothing goes its way.
//    `relay-client check` (its health) now fails, while
//    `relay-client check 127.0.0.1:7434`, relay-client's loopback forward to
//    the driver link, reaches the stub driver (StubDriver, on a free port
//    here, never the real 7434). Then ContainerEngine.startWrapper runs
//    /opt/visor/bin/agent-wrapper with a stand-in claude (FakeClaude, put
//    on Sessions, AGENT_WRAPPER_CLAUDE) and AGENT_DRIVER_URL
//    http://127.0.0.1:7434: it completes Connect (its hello naming the
//    agent, protocol 2, its token as the bearer), answers the driver's
//    message, is stopped by it, and ends 0.
// 6. Stopped, and everything made deleted.
//
// Exits 0 when every check passed, 1 when one failed (each is said).

import Foundation
import Synchronization
import VisorAgentProxyHost
import VisorContainer
import VisorContainerCore
import VisorProtocol
import VisorServer

struct ContainerCheck {
    let options: ContainerCheckOptions
    let scratch: Scratch

    init(options: ContainerCheckOptions) {
        self.options = options
        scratch = Scratch(sessions: options.sessions)
    }

    static func say(_ line: String) {
        print("\(Date().formatted(.iso8601)) \(line)")
        fflush(stdout)
    }

    func run() async -> Int32 {
        let host = ContainerHost.current
        Self.say("host: macOS \(host.systemVersion), Apple silicon \(host.isAppleSilicon), Virtualization \(host.virtualizationSupported)")
        guard host.canRunContainer else {
            Self.say("FAILED: this Mac can't run the container (bare metal, Apple silicon, macOS 26 or later only)")
            return 1
        }
        guard FileManager.default.fileExists(atPath: options.sessions) else {
            Self.say("FAILED: no Sessions volume at \(options.sessions)")
            return 1
        }
        var checks = Checks()
        do {
            try scratch.make()
            Self.say("scratch: \(scratch.root.path), \(scratch.sessions.path)")
            try await boot(&checks)
        } catch {
            checks.fail("the run", "\(error)")
        }
        scratch.remove(keepingData: options.keep)
        Self.say(options.keep ? "kept \(scratch.root.path); removed \(scratch.sessions.path)" : "removed \(scratch.root.path) and \(scratch.sessions.path)")
        Self.say(checks.summary)
        return checks.failed.isEmpty ? 0 : 1
    }

    private func boot(_ checks: inout Checks) async throws {
        // agent-proxy, in this process, on the throwaway data folder.
        guard let port = RelayPortChoice.choose(isFree: { LoopbackPort.isFree($0) }) else { throw CheckError("no loopback port is free for the relay") }
        let secrets = MemorySecrets()
        let places = AgentProxyHost.Places(dataDirectory: scratch.data)
        guard let running = AgentProxyHost.start(AgentProxySettings(relayPort: port), places: places, secrets: secrets, version: "e2e",
                                                 log: { Self.say("agent-proxy: \($0)") }), running.relay != nil else {
            throw CheckError("agent-proxy's relay listener didn't start on port \(port)")
        }
        let proxy = StopOnce { running.stop() }
        defer { proxy.stop() }
        let driver = StubDriver()
        let served = try await driver.start()
        defer { served.stop() }
        Self.say("the stub driver on 127.0.0.1:\(served.port)")
        let token = secrets.get(AgentProxySettings.secretKey(AgentProxySettings.relayTokenName))
        checks.record("agent-proxy's relay listener on loopback port \(port), its token made", token != nil && port != 7499)

        let images = ContainerizationBackend()
        let layout = scratch.layout
        let configuration = ContainerEngineConfiguration(enabled: true, cpus: options.cpus, memoryGiB: options.memoryGiB, idleMinutes: 30,
                                                         image: options.image, relayPort: port)
        let engine = ContainerEngine(context: ContainerEngine.Context(
            host: .current, locate: { layout }, linuxPrograms: options.linux, version: "e2e-\(scratch.id)", sessions: options.sessions,
            relaySocket: scratch.relaySocket, relayToken: { token }, driverPort: served.port, assets: images,
            backend: ContainerizationMachines(images: images),
            configuration: { configuration }, log: { Self.say($0) }))

        let started = Date()
        let status = await engine.start()
        Self.say("start: \(status.state.rawValue) in \(Int(Date().timeIntervalSince(started))) s; egress: \(status.egress ?? "-")")
        for error in status.errors { Self.say("  error: \(error)") }
        checks.record("it boots, and relay-client check passes through the relay (running)", status.state == .running)
        guard status.state == .running else {
            Self.say("boot log: \(Self.tail(layout.bootLog))")
            Self.say("relay-client: \(Self.tail(layout.log(process: "relay-client")))")
            _ = await engine.stop()
            return
        }
        await guestChecks(engine, layout: layout, &checks)
        await driverChecks(engine, driver, stopProxy: proxy.stop, &checks)
        let stopped = await engine.stop()
        checks.record("it stops", stopped.state == .stopped && !FileManager.default.fileExists(atPath: scratch.relaySocket.path)
                      && !FileManager.default.fileExists(atPath: engine.context.driverSocket.path))
        let egressLog = places.egressLog
        if let text = try? String(contentsOfFile: egressLog, encoding: .utf8) {
            Self.say("agent-proxy's egress log:\n" + text.split(separator: "\n").suffix(10).joined(separator: "\n"))
        }
    }

    private func guestChecks(_ engine: ContainerEngine, layout: ContainerLayout, _ checks: inout Checks) async {
        let check = await exec(engine, "relay-check-again", [ContainerEngine.relayClient, "check"])
        checks.record("relay-client check, run again: \(check.output)", check.status == 0)

        let uname = await exec(engine, "uname", ["uname", "-a"])
        checks.record("uname: \(uname.output)", uname.status == 0 && uname.output.hasPrefix("Linux"))

        // Sessions, both ways, at the same path.
        let folder = scratch.sessions.path
        let fromHost = "from the host \(scratch.id)", fromGuest = "from the guest \(scratch.id)"
        try? Data(fromHost.utf8).write(to: scratch.sessions.appendingPathComponent("from-host"))
        let write = await exec(engine, "sessions-write", ["/bin/sh", "-c", "cat '\(folder)/from-host' && printf '%s' '\(fromGuest)' > '\(folder)/from-guest'"])
        checks.record("the guest reads \(folder)/from-host", write.status == 0 && write.output.contains(fromHost))
        let written = (try? String(contentsOf: scratch.sessions.appendingPathComponent("from-guest"), encoding: .utf8)) ?? ""
        let owner = (try? FileManager.default.attributesOfItem(atPath: folder + "/from-guest"))?[.ownerAccountID] as? NSNumber
        checks.record("the host reads \(folder)/from-guest, the guest's (owner uid \(owner.map { "\($0)" } ?? "?"), this user \(getuid()))",
                      written == fromGuest && owner?.uint32Value == getuid())

        // No LAN: no interface but loopback, and agent-proxy refusing this
        // Mac's own address and a private one.
        let interfaces = await exec(engine, "interfaces", ["/bin/sh", "-c", "ls /sys/class/net"])
        checks.record("the guest's interfaces: \(interfaces.output)",
                      interfaces.status == 0 && interfaces.output.split(whereSeparator: \.isWhitespace) == ["lo"])
        for target in Self.lanTargets() {
            let lan = await exec(engine, "lan-\(target.replacingOccurrences(of: ":", with: "-"))", [ContainerEngine.relayClient, "check", target])
            checks.record("no LAN: \(target) refused (\(lan.output))", lan.status != 0)
        }
    }

    /// The driver link, with agent-proxy stopped: the forward reaches the
    /// stub driver, and agent-wrapper with a stand-in claude completes
    /// Connect through it, answers, and ends when it's stopped.
    private func driverChecks(_ engine: ContainerEngine, _ driver: StubDriver, stopProxy: () -> Void, _ checks: inout Checks) async {
        stopProxy()
        let health = await exec(engine, "relay-check-no-proxy", [ContainerEngine.relayClient, "check"])
        checks.record("agent-proxy stopped: relay-client check fails (\(health.output))", health.status != 0)
        let forward = await exec(engine, "driver-forward", [ContainerEngine.relayClient, "check", "127.0.0.1:\(ContainerEngine.driverPortInGuest)"])
        checks.record("127.0.0.1:\(ContainerEngine.driverPortInGuest) in the guest reaches the stub driver (\(forward.output))", forward.status == 0)

        let id = UUID().uuidString.lowercased()
        let claude = scratch.sessions.appendingPathComponent("fake-claude.py")
        do {
            try Data(FakeClaude.script.utf8).write(to: claude)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        } catch {
            checks.fail("the stand-in claude", "\(error)")
            return
        }
        let token = "e2e-token-\(scratch.id)"
        let session = ContainerSession(id: id, dispatcherURL: "http://127.0.0.1:\(ContainerEngine.driverPortInGuest)", title: "e2e \(scratch.id)",
                                       workingDirectory: scratch.sessions.appendingPathComponent("Claude/\(id)").path, skipPermissions: true,
                                       token: token, claudeProgram: claude.path)
        let status: Int32?
        let log: URL?
        do {
            let execution = try await engine.startWrapper(session: session)
            log = execution.log
            status = await Self.wait(execution, seconds: 120)
        } catch {
            checks.fail("agent-wrapper started", "\(error)")
            return
        }
        let heard = driver.heard.withLock { $0 }
        let hello = heard.hello
        checks.record("agent-wrapper completes Connect through the driver link (hello: agent \(hello?.agent.uuid ?? "-"), "
                      + "protocol \(hello.map { "\($0.protocol)" } ?? "-"), the bearer \(heard.bearer == token ? "its token" : "\(heard.bearer ?? "none")"))",
                      hello?.agent.uuid == id && (hello?.protocol ?? 0) >= 2 && heard.bearer == token)
        checks.record("the agent answers the driver's message (\(StubDriver.message))", heard.answered)
        checks.record("stopped by the driver, agent-wrapper ends 0 (\(status.map { "\($0)" } ?? "still running after 120 s"); "
                      + "ended: \(heard.ended ?? "-"))", status == 0)
        if status != 0, let log { Self.say("agent-wrapper's log:\n" + Self.tail(log)) }
    }

    /// A process's status, or nil if it ran past `seconds` (then killed).
    private static func wait(_ execution: ContainerExecution, seconds: Int) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await execution.wait() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil { try? await execution.signal(9) }
            group.cancelAll()
            return first
        }
    }

    /// A process run in the guest: its status and what it wrote.
    private func exec(_ engine: ContainerEngine, _ id: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        do {
            let execution = try await engine.exec(ContainerExec(id: id, arguments: arguments))
            let status = await execution.wait()
            let output = ((try? String(contentsOf: execution.log, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (status, output.replacingOccurrences(of: "\n", with: " | "))
        } catch {
            return (-1, "\(error)")
        }
    }

    /// This Mac's own private IPv4 addresses' port 80 and the usual
    /// router's: none may be reached from the guest.
    static func lanTargets() -> [String] {
        var targets = ["192.168.1.1:80", "10.0.0.1:80"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return targets }
        defer { freeifaddrs(list) }
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !text.hasPrefix("127."), !targets.contains("\(text):80") { targets.append("\(text):80") }
        }
        return targets
    }

    static func tail(_ url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "(none)"
        return text.split(separator: "\n").suffix(30).joined(separator: "\n")
    }
}

/// agent-proxy's listeners stopped once, whichever asks first (the driver
/// checks, or the end).
private final class StopOnce: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    init(_ action: @escaping @Sendable () -> Void) { self.action = Mutex(action) }

    func stop() {
        let action = self.action.withLock { held in
            defer { held = nil }
            return held
        }
        action?()
    }
}

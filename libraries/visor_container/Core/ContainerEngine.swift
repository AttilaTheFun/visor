// The Sessions container's engine (docs/containers.md), in Visor's
// background server: one long-lived container per Mac, booted from the
// assets on the Containers volume (Kata's kernel, vminit, a clone of the
// agent image's template), with no network interface, Sessions shared at
// the same path, Visor's Linux programs read-only at /opt/visor/bin, and
// agent-proxy's relay carried in as its only way out (HostRelay).
//
// - Started on first use (an exec, or Start), stopped once nothing has run
//   in it and no session has been placed in it for the idle minutes, and
//   started again at a server's start when a session is placed in it.
// - Visor's driver (agent_protocol's AgentDriver, 127.0.0.1:7434 on the Mac)
//   carried in too, on a socket of its own (the driver link, a UnixBridge
//   with no header: the agents' JWTs authenticate them) at
//   /run/visor/driver.sock, which relay-client forwards from the guest's
//   loopback (`--forward 7434=…`): the agents' wrappers dial
//   AGENT_DRIVER_URL=http://127.0.0.1:7434, as on the Mac, whether or not
//   agent-proxy's relay is up (startWrapper, for step 4's sessions).
// - Before it boots, the relay-client link check (ToolsFolder's rule on the
//   programs' copy); once booted, `relay-client check` run in it, asking
//   agent-proxy's health through the relay. If either fails it shows "no
//   egress", and processes (sessions) are refused.
// - An update restarts the server, and the container with it: the sessions
//   resume from Sessions (step 4's), a turn in progress interrupted.
//
// The VM itself is the backend's (ContainerBackend: Apple's Containerization
// on a Mac, a fake in the tests), so all of this is tested without
// virtualization.

import Foundation
import VisorProtocol

public actor ContainerEngine {
    public nonisolated let context: Context

    /// Its name in the guest (the hostname) and to Containerization.
    public static let name = "visor-sessions"
    /// Where Visor's Linux programs are in the guest.
    public static let toolsInGuest = "/opt/visor/bin"
    /// relay-client in the guest.
    public static let relayClient = toolsInGuest + "/relay-client"
    /// agent_protocol's agent-wrapper in the guest: each session's agent.
    public static let agentWrapper = toolsInGuest + "/agent-wrapper"
    /// The driver link's socket in the guest.
    public static let driverInGuest = "/run/visor/driver.sock"
    /// The guest's loopback port relay-client forwards to it: the driver's
    /// port on the Mac, so the URL is the same in and out.
    public static let driverPortInGuest: UInt16 = 7434
    /// What the agents in it dial (AGENT_DRIVER_URL).
    public static let driverURL = "http://127.0.0.1:\(driverPortInGuest)"
    /// What the main process runs under relay-client: a process that waits,
    /// so everything else is exec'd.
    public static let waits = ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 86400 & wait $!; done"]
    /// The most errors kept for the status.
    static let errorsKept = 5

    var state: ContainerState = .stopped
    var since: Date
    var machine: (any ContainerMachine)?
    var relay: HostRelay?
    /// The driver link: the guest's /run/visor/driver.sock to Visor's driver.
    var driverLink: UnixBridge?
    var layout: ContainerLayout?
    /// What the running container was started with.
    var booted: (cpus: Int, memoryGiB: Int, image: ImageDigest)?
    /// Each boot's number: what a late word from an earlier one is told apart by.
    var generation = 0
    var starting: Task<Void, any Error>?
    var executions: [String: ContainerExecution] = [:]
    /// Since when nothing has run in it (nil while something does).
    var idleSince: Date?
    var egress: String?
    var errors: [String] = []
    var idleLoop: Task<Void, Never>?

    public init(context: Context) {
        self.context = context
        since = context.now()
    }

    /// How it stands now.
    public func status() -> ContainerStatus {
        let configuration = context.configuration()
        let canRun = context.host.canRunContainer
        let shown: ContainerState = machine == nil && starting == nil && (!configuration.enabled || !canRun) ? .off : state
        return ContainerStatus(state: shown, enabled: configuration.enabled, canRun: canRun,
                               cpus: booted?.cpus ?? configuration.cpus, memoryGiB: booted?.memoryGiB ?? configuration.memoryGiB,
                               idleMinutes: configuration.idleMinutes, image: (booted?.image ?? configuration.image)?.value,
                               since: since.timeIntervalSince1970, processes: executions.count, relayPort: configuration.relayPort,
                               egress: egress, errors: errors)
    }

    /// Started if it isn't running (Settings' Start, `POST /api/container/start`);
    /// with no egress, its check run again. How it stands after.
    public func start() async -> ContainerStatus {
        do {
            if state == .noEgress, machine != nil {
                try await checkEgressAgain()
            } else {
                try await ensureStarted()
            }
        } catch {
            note(error)
        }
        return status()
    }

    /// Stopped (Settings' Stop, `POST /api/container/stop`): what runs in it
    /// ends. How it stands after.
    public func stop() async -> ContainerStatus {
        await stop(reason: "stopped by hand")
        return status()
    }

    /// The server has started: the container started again if a session is
    /// placed in it, and the idle stop watched.
    public func serverStarted(idleCheckEvery interval: Duration = .seconds(30)) async {
        if idleLoop == nil {
            idleLoop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    await self?.tick()
                }
            }
        }
        let configuration = context.configuration()
        guard configuration.enabled, context.host.canRunContainer else { return }
        let placed = await context.placedSessions()
        guard placed > 0 else { return }
        context.log("container: \(placed) session(s) placed in it: started with the server")
        do { try await ensureStarted() } catch { note(error) }
    }

    /// The settings changed: turned off, it's stopped; anything else takes
    /// effect at its next start.
    public func configurationChanged() async {
        let configuration = context.configuration()
        if (!configuration.enabled || !context.host.canRunContainer), machine != nil || starting != nil {
            await stop(reason: "turned off in Settings")
        } else if machine == nil, starting == nil {
            set(configuration.enabled && context.host.canRunContainer ? (state == .noEgress ? .noEgress : .stopped) : .off)
        }
    }

    /// Stopped, whatever it was doing; a start under way finished first.
    func stop(reason: String) async {
        if let starting { _ = try? await starting.value }
        guard let machine else {
            stopLinks()
            if state != .starting { set(context.configuration().enabled && context.host.canRunContainer ? .stopped : .off) }
            return
        }
        context.log("container: stopping (\(reason))")
        self.machine = nil
        generation += 1
        await machine.stop()
        stopLinks()
        booted = nil
        executions.removeAll()
        idleSince = nil
        let configuration = context.configuration()
        set(configuration.enabled && context.host.canRunContainer ? .stopped : .off)
        context.log("container: stopped (\(reason))")
    }

    /// The relay and the driver link stopped, their sockets gone.
    func stopLinks() {
        relay?.stop()
        relay = nil
        driverLink?.stop()
        driverLink = nil
    }

    func set(_ next: ContainerState) {
        guard next != state else { return }
        state = next
        since = context.now()
    }

    /// An error kept for the status, and logged.
    func note(_ error: any Error) {
        note((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    func note(_ text: String) {
        context.log("container: \(text)")
        errors.append(text)
        if errors.count > Self.errorsKept { errors.removeFirst(errors.count - Self.errorsKept) }
    }
}

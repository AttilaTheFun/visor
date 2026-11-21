// Starting the Sessions container: the assets had (fetched once, checked
// each time), Visor's Linux programs staged under the link rule (the
// relay-client link check, before the boot), the root filesystem cloned
// from the template when there's none of this image, the relay and the
// driver link listening, the boot, and then `relay-client check` run in it
// (the egress check).

import Foundation
import VisorProtocol

extension ContainerEngine {
    /// Running (or with no egress) once this returns; one start at a time,
    /// a second caller waiting for the first's.
    func ensureStarted() async throws {
        if machine != nil, state == .running || state == .noEgress { return }
        if let starting { return try await starting.value }
        // Started again (an exec, Start, a server's start): no longer held.
        held = nil
        let task = Task { try await self.boot() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func boot() async throws {
        let configuration = context.configuration()
        guard configuration.enabled else { throw ContainerEngineError.off }
        guard context.host.canRunContainer else {
            throw ContainerEngineError.cannotRun("it needs macOS 26 or later on Apple silicon, where Virtualization can make a VM "
                                                 + "(this is macOS \(context.host.systemVersion)).")
        }
        set(.starting)
        do {
            try await bootChecked(configuration)
        } catch {
            // A failed check has said "no egress" already; anything else
            // leaves it stopped.
            if state == .starting { set(.stopped) }
            throw error
        }
    }

    private func bootChecked(_ configuration: ContainerEngineConfiguration) async throws {
        let layout = try context.locate()
        self.layout = layout
        guard let image = configuration.image else { throw ContainerAssetsError.noImagePinned }
        let assets = try await ContainerAssets(layout: layout, image: image, pins: context.pins, backend: context.assets, log: context.log).prepare()

        // The relay-client link check, before the boot: a relay-client that
        // doesn't resolve inside the mount would leave it with no way out.
        let tools: URL
        do {
            guard let programs = context.linuxPrograms else { throw ContainerAssetsError.toolMissing("relay-client (this build has no Linux programs)") }
            tools = try ToolsFolder.stage(from: programs, layout: layout, version: context.version)
        } catch {
            throw noEgress("the relay-client link check failed: \(Self.describe(error))")
        }
        guard let port = configuration.relayPort else { throw noEgress(ContainerEngineError.noRelayPort.description) }

        let rootfs = try prepareRootfs(layout, template: assets.template, image: image)
        try FileManager.default.createDirectory(at: layout.logs, withIntermediateDirectories: true)
        let relay = HostRelay(socketPath: context.relaySocket.path, port: port, token: context.relayToken, log: context.log)
        try relay.start()
        let driverLink = Self.driverLink(context)
        do {
            try driverLink.start()
        } catch {
            relay.stop()
            throw error
        }
        let spec = ContainerBootSpec(
            name: Self.name, kernel: assets.kernel, initfs: assets.initfs, rootfs: rootfs, image: image.reference(), store: layout.store,
            cpus: configuration.cpus, memoryBytes: UInt64(configuration.memoryGiB) << 30, shares: shares(tools, configuration),
            sockets: [ContainerBootSpec.Socket(host: context.relaySocket.path, guest: HostRelay.guestPath),
                      ContainerBootSpec.Socket(host: context.driverSocket.path, guest: Self.driverInGuest)],
            arguments: Self.mainArguments, mainLog: layout.log(process: "relay-client"), bootLog: layout.bootLog)
        context.log("container: booting \(image.reference()) (\(configuration.cpus) CPUs, \(configuration.memoryGiB) GiB, no network), "
                    + "relayed to agent-proxy on port \(port), Visor's driver at \(Self.driverURL) in it")
        let machine: any ContainerMachine
        do {
            machine = try await context.backend.boot(spec)
        } catch {
            relay.stop()
            driverLink.stop()
            throw error
        }
        generation += 1
        let booting = generation
        self.machine = machine
        self.relay = relay
        self.driverLink = driverLink
        booted = (configuration.cpus, configuration.memoryGiB, image)
        idleSince = context.now()
        Task { [weak self] in
            let status = await machine.waitMain()
            await self?.mainEnded(status, generation: booting)
        }
        try await checkEgressAgain()
    }

    /// The main process: relay-client, the relay its way out and the
    /// driver's port forwarded on its loopback, running a process that waits.
    static var mainArguments: [String] {
        [relayClient, "run", "--relay", HostRelay.guestPath, "--forward", "\(driverPortInGuest)=\(driverInGuest)", "--"] + waits
    }

    /// The driver link: the guest's connections on /run/visor/driver.sock
    /// to Visor's driver on loopback, with no header (the agents' JWTs
    /// authenticate them; nothing of agent-proxy's is in the way).
    static func driverLink(_ context: Context) -> UnixBridge {
        UnixBridge(name: "driver link", target: "Visor's driver", socketPath: context.driverSocket.path, port: context.driverPort,
                   opening: { .plain }, log: context.log)
    }

    /// The folders shared in: Sessions read-write at the same path, the
    /// programs read-only at /opt/visor/bin, and the checkouts' folder
    /// where the settings name one.
    func shares(_ tools: URL, _ configuration: ContainerEngineConfiguration) -> [ContainerBootSpec.Share] {
        var shares = [ContainerBootSpec.Share(source: context.sessions, destination: context.sessions, readOnly: false),
                      ContainerBootSpec.Share(source: tools.path, destination: Self.toolsInGuest, readOnly: true)]
        if let checkouts = configuration.checkouts, checkouts != context.sessions, !checkouts.hasPrefix(context.sessions + "/") {
            shares.append(ContainerBootSpec.Share(source: checkouts, destination: checkouts, readOnly: false))
        }
        return shares
    }

    /// sessions/rootfs.ext4: kept while it's of this image, else a new
    /// clone of the template (APFS clones it: only what's written takes
    /// room), made beside it and moved into place once whole.
    func prepareRootfs(_ layout: ContainerLayout, template: URL, image: ImageDigest) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: layout.sessionsFolder, withIntermediateDirectories: true)
        if files.fileExists(atPath: layout.rootfs.path), RootfsRecord.read(layout.rootfsRecord)?.image == image.value {
            return layout.rootfs
        }
        context.log("container: a new root filesystem, cloned from \(template.lastPathComponent)")
        let partial = layout.sessionsFolder.appendingPathComponent(".rootfs.partial-\(UUID().uuidString).ext4")
        defer { try? files.removeItem(at: partial) }
        try files.copyItem(at: template, to: partial)
        try? files.removeItem(at: layout.rootfsRecord)
        try? files.removeItem(at: layout.rootfs)
        try files.moveItem(at: partial, to: layout.rootfs)
        try RootfsRecord(image: image.value, template: template.lastPathComponent).write(layout.rootfsRecord)
        return layout.rootfs
    }

    /// `relay-client check` in it, a few tries: running if it passes, no
    /// egress (and the error) if it doesn't.
    func checkEgressAgain() async throws {
        guard let machine, let layout else { throw ContainerEngineError.notRunning }
        let booting = generation
        var said = ""
        for attempt in 1...3 {
            let log = layout.log(process: "relay-check")
            let spec = ContainerProcessSpec(id: "relay-check-\(booting)-\(attempt)", arguments: [Self.relayClient, "check"], log: log)
            let before = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
            let status: Int32?
            do {
                status = try await Self.run(machine.exec(spec), within: context.checkTimeout)
            } catch {
                status = nil
                said = Self.describe(error)
            }
            guard generation == booting, self.machine != nil else { throw ContainerEngineError.notRunning }
            let output = Self.tail(log, from: before)
            if status == 0 {
                egress = "relay-client check passed" + (output.isEmpty ? "" : ": \(output)")
                set(.running)
                context.log("container: running, \(egress ?? "")")
                return
            }
            said = status.map { "relay-client check ended \($0)" + (output.isEmpty ? "" : ": \(output)") }
                ?? (said.isEmpty ? "relay-client check didn't end within \(context.checkTimeout)" : said)
            if attempt < 3 { try? await Task.sleep(for: context.checkRetryPause) }
        }
        throw noEgress(said)
    }

    /// No egress: the state, what the check said, and the error to throw.
    func noEgress(_ why: String) -> ContainerEngineError {
        egress = why
        set(.noEgress)
        return .noEgress(why)
    }

    /// The main process (relay-client) ended: the container is gone with it.
    func mainEnded(_ status: Int32, generation ended: Int) async {
        guard ended == generation, machine != nil else { return }
        note("its main process (relay-client) ended with \(status): the container stopped")
        await stop(reason: "its main process ended")
    }

    /// A process's status, or nil if it didn't end within `limit` (it's
    /// killed then).
    static func run(_ process: any ContainerMachineProcess, within limit: Duration) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask { (try? await process.wait()) ?? -1 }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil { try? await process.signal(9) }
            group.cancelAll()
            return first == -1 ? nil : first
        }
    }

    /// The last line written to `log` after `offset`.
    static func tail(_ log: URL, from offset: Int) -> String {
        guard let data = try? Data(contentsOf: log), data.count > offset else { return "" }
        let text = String(decoding: data[offset...], as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

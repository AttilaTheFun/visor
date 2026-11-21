// The container engine against a fake backend (no VM, no virtualization):
// what it boots (no network, Sessions and the programs shared, the relay
// carried in, relay-client as the main process), the relay-client link check
// before the boot and `relay-client check` after it ("no egress" refusing
// processes), the first use starting it, the idle stop, the start with a
// server for sessions placed in it, the root filesystem kept or cloned
// again, a crash, and turning it off.

import Foundation
import Synchronization
import Testing
import VisorContainerCore
import VisorProtocol

@Suite struct EngineTests {
    /// What a test changes as it goes: the settings, the clock, the sessions placed.
    final class Rig: Sendable {
        let root: URL
        let socketFolder: URL
        let programs: URL
        let assets: FakeBackend
        let machines = FakeMachines()
        let configuration: Mutex<ContainerEngineConfiguration>
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let placed = Mutex(0)
        let host: Mutex<ContainerHost>

        init(assets: FakeBackend) throws {
            let name = UUID().uuidString.prefix(8)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("container-engine-\(name)", isDirectory: true)
            // A socket's path must be short: not under the long temporary folder.
            socketFolder = URL(fileURLWithPath: "/tmp/vce-\(name)", isDirectory: true)
            programs = root.appendingPathComponent("Linux", isDirectory: true)
            self.assets = assets
            configuration = Mutex(ContainerEngineConfiguration(enabled: true, cpus: 4, memoryGiB: 8, idleMinutes: 30, image: AssetsTests.image,
                                                               relayPort: 7438))
            host = Mutex(ContainerHost(systemVersion: "26.1", isMacOS26OrLater: true, isAppleSilicon: true, virtualizationSupported: true))
            try FileManager.default.createDirectory(at: programs, withIntermediateDirectories: true)
            let server = programs.appendingPathComponent("visor-server")
            try Data("#!/bin/sh\n".utf8).write(to: server)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
            let wrapper = programs.appendingPathComponent("agent-wrapper")
            try Data("#!/bin/sh\n# agent-wrapper\n".utf8).write(to: wrapper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            for name in ["relay-client", "visor-agent-host"] {
                try FileManager.default.createSymbolicLink(atPath: programs.appendingPathComponent(name).path, withDestinationPath: "visor-server")
            }
        }

        var layout: ContainerLayout { ContainerLayout(root: root.appendingPathComponent("Containers/Visor", isDirectory: true)) }

        func engine(sessions: String = "/Volumes/Sessions", driverPort: Int = 7434) -> ContainerEngine {
            let layout = layout
            return ContainerEngine(context: ContainerEngine.Context(
                host: host.withLock { $0 }, locate: { layout }, linuxPrograms: programs, version: "0.64.7", sessions: sessions,
                relaySocket: socketFolder.appendingPathComponent("relay.sock"), relayToken: { "relay-secret" }, driverPort: driverPort, assets: assets,
                pins: AssetsTests.pins(), backend: machines, configuration: { self.configuration.withLock { $0 } },
                placedSessions: { self.placed.withLock { $0 } }, now: { self.clock.withLock { $0 } },
                checkTimeout: .seconds(2), checkRetryPause: .milliseconds(10)))
        }

        func change(_ edit: (inout ContainerEngineConfiguration) -> Void) { configuration.withLock { edit(&$0) } }
        func advance(minutes: Double) { clock.withLock { $0 = $0.addingTimeInterval(minutes * 60) } }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketFolder)
        }
    }

    func rig() async throws -> Rig {
        let assets = FakeBackend(archive: AssetsTests.archive)
        await assets.setDigests(ContainerPins.current.initfs.reference, [ContainerPins.current.initfs.digest])
        await assets.setDigests(AssetsTests.image.reference(), [AssetsTests.image.value])
        return try Rig(assets: assets)
    }

    @Test func itBootsWithNoNetworkSessionsSharedAndTheRelayCarriedIn() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let engine = rig.engine()
        let status = await engine.start()
        #expect(status.state == .running, "\(status.errors)")
        #expect(status.egress?.hasPrefix("relay-client check passed") == true)
        let machine = try #require(await rig.machines.last)
        let spec = machine.spec
        let layout = rig.layout
        #expect(spec.name == "visor-sessions")
        #expect(spec.cpus == 4 && spec.memoryBytes == 8 << 30)
        #expect(spec.kernel == layout.kernel && spec.initfs == layout.initfs(digest: ContainerPins.current.initfs.digest))
        #expect(spec.rootfs == layout.rootfs)
        #expect(spec.image == AssetsTests.image.reference())
        #expect(spec.shares == [
            ContainerBootSpec.Share(source: "/Volumes/Sessions", destination: "/Volumes/Sessions", readOnly: false),
            ContainerBootSpec.Share(source: layout.tools(version: "0.64.7")!.path, destination: "/opt/visor/bin", readOnly: true),
        ])
        // The relay, and the driver link beside it (the same folder).
        #expect(spec.sockets == [ContainerBootSpec.Socket(host: rig.socketFolder.appendingPathComponent("relay.sock").path,
                                                          guest: "/run/agent-proxy/relay.sock"),
                                 ContainerBootSpec.Socket(host: rig.socketFolder.appendingPathComponent("driver.sock").path,
                                                          guest: "/run/visor/driver.sock")])
        #expect(spec.arguments.prefix(7) == ["/opt/visor/bin/relay-client", "run", "--relay", "/run/agent-proxy/relay.sock",
                                             "--forward", "7434=/run/visor/driver.sock", "--"])
        // The root filesystem is the template's clone, and says of which image.
        #expect(try Data(contentsOf: layout.rootfs) == Data(contentsOf: layout.template(image: AssetsTests.image)))
        #expect(try String(contentsOf: layout.rootfsRecord, encoding: .utf8).contains(AssetsTests.image.value))
        // Its egress check, then nothing else.
        #expect(await machine.execs.map(\.arguments) == [["/opt/visor/bin/relay-client", "check"]])
        // The relay and the driver link listen on the host's side.
        #expect(FileManager.default.fileExists(atPath: rig.socketFolder.appendingPathComponent("relay.sock").path))
        #expect(FileManager.default.fileExists(atPath: rig.socketFolder.appendingPathComponent("driver.sock").path))
        // The status, as the API says it.
        #expect(ContainerStatus(json: status.json) == status)
        #expect(status.cpus == 4 && status.memoryGiB == 8 && status.image == AssetsTests.image.value && status.relayPort == 7438)
        _ = await engine.stop()
    }

    @Test func theCheckoutsAreSharedOnlyWhereTheSettingsNameAFolder() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        rig.change { $0.checkouts = "/Volumes/Work" }
        let engine = rig.engine()
        _ = await engine.start()
        let spec = try #require(await rig.machines.last).spec
        #expect(spec.shares.last == ContainerBootSpec.Share(source: "/Volumes/Work", destination: "/Volumes/Work", readOnly: false))
        _ = await engine.stop()
    }

    @Test func offItBootsNothingAndRefusesProcesses() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        rig.change { $0.enabled = false }
        let engine = rig.engine()
        #expect(await engine.status().state == .off)
        let status = await engine.start()
        #expect(status.state == .off && status.errors.last == ContainerEngineError.off.description)
        await #expect(throws: ContainerEngineError.off) { _ = try await engine.exec(ContainerExec(id: "s1", arguments: ["true"])) }
        #expect(await rig.machines.boots.isEmpty)
    }

    @Test func aMacThatCantRunItIsOff() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        rig.host.withLock { $0.virtualizationSupported = false }
        let engine = rig.engine()
        let status = await engine.start()
        #expect(status.state == .off && !status.canRun)
        #expect(await rig.machines.boots.isEmpty)
    }

    @Test func aFailedEgressCheckIsNoEgressAndRefusesProcesses() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        await rig.machines.setCheckStatus(1)
        let engine = rig.engine()
        let status = await engine.start()
        #expect(status.state == .noEgress)
        #expect(status.egress?.contains("relay-client check ended 1") == true)
        let machine = try #require(await rig.machines.last)
        #expect(await machine.checks == 3, "tried three times")
        await #expect(throws: ContainerEngineError.self) { _ = try await engine.exec(ContainerExec(id: "s1", arguments: ["agent-wrapper"])) }
        #expect(await machine.execs.allSatisfy { $0.arguments.last == "check" }, "no session's process started")
        // Checked again (Settings' Check Again): agent-proxy answers now.
        await rig.machines.setCheckStatus(0)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await engine.start().state == .running)
        #expect(await rig.machines.boots.count == 1, "the same container, checked again")
        _ = await engine.stop()
    }

    @Test func aDanglingRelayClientLinkIsNoEgressBeforeAnyBoot() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let link = rig.programs.appendingPathComponent("relay-client")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "relay-client-gone")
        let engine = rig.engine()
        let status = await engine.start()
        #expect(status.state == .noEgress)
        #expect(status.egress?.contains("the relay-client link check failed") == true)
        #expect(status.egress?.contains("dangling") == true)
        #expect(await rig.machines.boots.isEmpty)
        await #expect(throws: ContainerEngineError.self) { _ = try await engine.exec(ContainerExec(id: "s1", arguments: ["true"])) }
    }

    @Test func anAbsoluteRelayClientLinkIsNoEgressToo() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let link = rig.programs.appendingPathComponent("relay-client")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: rig.programs.appendingPathComponent("visor-server").path)
        let status = await rig.engine().start()
        #expect(status.state == .noEgress && status.egress?.contains("absolute") == true)
        #expect(await rig.machines.boots.isEmpty)
    }

    @Test func noRelayPortIsNoEgress() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        rig.change { $0.relayPort = nil }
        let status = await rig.engine().start()
        #expect(status.state == .noEgress && status.egress?.contains("relay port") == true)
        #expect(await rig.machines.boots.isEmpty)
    }

    @Test func aProcessStartsItOnFirstUseAndIsSignalledAndWaitedOn() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let engine = rig.engine()
        #expect(await engine.status().state == .stopped)
        let execution = try await engine.exec(ContainerExec(id: "session-1", arguments: ["/opt/visor/bin/agent-wrapper"],
                                                            environment: ["AGENT_ID": "session-1"], workingDirectory: "/Volumes/Sessions/Claude/x"))
        #expect(await engine.status().state == .running)
        #expect(await engine.status().processes == 1)
        #expect(execution.log == rig.layout.log(process: "session-1"))
        let machine = try #require(await rig.machines.last)
        let spec = try #require(await machine.execs.last)
        #expect(spec.environment == ["AGENT_ID": "session-1"] && spec.workingDirectory == "/Volumes/Sessions/Claude/x")
        await #expect(throws: ContainerEngineError.duplicateProcess("session-1")) {
            _ = try await engine.exec(ContainerExec(id: "session-1", arguments: ["true"]))
        }
        try await execution.signal(15)
        #expect(await execution.wait() == 143)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await engine.status().processes == 0)
        _ = await engine.stop()
    }

    @Test func itStopsOnceIdleForTheSettingsMinutes() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        rig.change { $0.idleMinutes = 10 }
        let engine = rig.engine()
        let execution = try await engine.exec(ContainerExec(id: "s1", arguments: ["sleep", "infinity"]))
        rig.advance(minutes: 60)
        await engine.tick()
        #expect(await engine.status().state == .running, "not idle while something runs in it")
        try await execution.signal(9)
        _ = await execution.wait()
        try await Task.sleep(for: .milliseconds(20))
        rig.advance(minutes: 9)
        await engine.tick()
        #expect(await engine.status().state == .running, "9 of its 10 minutes")
        // A session placed in it keeps it up.
        rig.placed.withLock { $0 = 1 }
        rig.advance(minutes: 5)
        await engine.tick()
        #expect(await engine.status().state == .running)
        rig.placed.withLock { $0 = 0 }
        await engine.tick()
        rig.advance(minutes: 10)
        await engine.tick()
        #expect(await engine.status().state == .stopped)
        #expect(await rig.machines.last?.stopped == true)
        #expect(!FileManager.default.fileExists(atPath: rig.socketFolder.appendingPathComponent("relay.sock").path), "the relay gone with it")
    }

    @Test func aServerStartStartsItForSessionsPlacedInIt() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let idle = rig.engine()
        await idle.serverStarted(idleCheckEvery: .seconds(3600))
        #expect(await idle.status().state == .stopped, "nothing placed in it: not started")
        #expect(await rig.machines.boots.isEmpty)
        rig.placed.withLock { $0 = 2 }
        let engine = rig.engine()
        await engine.serverStarted(idleCheckEvery: .seconds(3600))
        #expect(await engine.status().state == .running)
        #expect(await rig.machines.boots.count == 1)
        _ = await engine.stop()
    }

    @Test func theRootFilesystemIsKeptForTheSameImageAndClonedForANewOne() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let engine = rig.engine()
        _ = await engine.start()
        _ = await engine.stop()
        // What an agent installed in it is still there at the next start.
        try Data("installed".utf8).write(to: rig.layout.rootfs)
        _ = await engine.start()
        #expect(try String(contentsOf: rig.layout.rootfs, encoding: .utf8) == "installed")
        _ = await engine.stop()
        // A new image: a new clone, of its template.
        let next = ImageDigest("sha256:" + String(repeating: "cd", count: 32))!
        await rig.assets.setDigests(next.reference(), [next.value])
        rig.change { $0.image = next }
        let status = await engine.start()
        #expect(status.state == .running && status.image == next.value)
        #expect(try Data(contentsOf: rig.layout.rootfs) == Data(contentsOf: rig.layout.template(image: next)))
        _ = await engine.stop()
    }

    @Test func itsMainProcessEndingStopsIt() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let engine = rig.engine()
        let execution = try await engine.exec(ContainerExec(id: "s1", arguments: ["sleep", "infinity"]))
        await rig.machines.last?.crash(70)
        #expect(await execution.wait() == 137)
        try await Task.sleep(for: .milliseconds(50))
        let status = await engine.status()
        #expect(status.state == .stopped && status.processes == 0)
        #expect(status.errors.last?.contains("ended with 70") == true)
        // Its next use starts it again.
        _ = try await engine.exec(ContainerExec(id: "s2", arguments: ["true"]))
        #expect(await rig.machines.boots.count == 2)
        _ = await engine.stop()
    }

    @Test func turnedOffItIsStopped() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let engine = rig.engine()
        _ = await engine.start()
        rig.change { $0.enabled = false }
        await engine.configurationChanged()
        #expect(await engine.status().state == .off)
        #expect(await rig.machines.last?.stopped == true)
    }

    @Test func twoStartsAtOnceBootOnce() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let engine = rig.engine()
        async let first = engine.start()
        async let second = engine.start()
        let both = await [first, second]
        #expect(both.allSatisfy { $0.state == .running })
        #expect(await rig.machines.boots.count == 1)
        _ = await engine.stop()
    }

    @Test func aFailedBootIsStoppedWithItsError() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        await rig.machines.setFailBoot(true)
        let engine = rig.engine()
        let status = await engine.start()
        #expect(status.state == .stopped && status.errors.last == "the fake VM wouldn't boot")
        #expect(!FileManager.default.fileExists(atPath: rig.socketFolder.appendingPathComponent("relay.sock").path))
    }

    @Test func aProcessLogsUnderItsIdSafely() {
        let layout = ContainerLayout(root: URL(fileURLWithPath: "/c/Visor"))
        #expect(layout.log(process: "session-1").path == "/c/Visor/sessions/logs/session-1.log")
        #expect(layout.log(process: "../x/y").path == "/c/Visor/sessions/logs/_.._x_y.log")
    }
}

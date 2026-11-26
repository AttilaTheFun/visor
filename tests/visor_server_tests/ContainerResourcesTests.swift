// The Sessions container's CPUs, memory cap and idle minutes over `PUT
// /api/settings` (VisorServer+ContainerResources): their JSON, each within
// this computer's or refused with why (never clamped), `null` or
// `"default"` back to the default, kept in the settings file, said in
// `GET /api/settings` with the limits, and what `GET /api/container` says
// once the engine is told.

import Foundation
import Synchronization
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class ContainerResourcesTests {
    /// An engine that says what the settings it was told would start it with.
    final class SettingsEngine: SessionsContainer {
        let told = Mutex<ServerSettings?>(nil)

        func status() async -> ContainerStatus {
            let container = told.withLock { $0?.container } ?? ContainerSettings()
            return ContainerStatus(state: .stopped, enabled: container.enabled, canRun: true, cpus: container.resolvedCPUs(cores: 10),
                                   memoryGiB: container.resolvedMemoryGiB(availableBytes: 20 << 30, physicalBytes: 32 << 30),
                                   idleMinutes: container.idleMinutes)
        }

        func start() async -> ContainerStatus { await status() }
        func stop() async -> ContainerStatus { await status() }
        func restart() async -> ContainerStatus { await status() }
        var sharedFolders: [String] { ["/Volumes/Sessions"] }
        func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun { throw CancellationError() }
        func settingsChanged(_ settings: ServerSettings) { told.withLock { $0 = settings } }
        func loopbackPortIsFree(_ port: Int) -> Bool { true }
    }

    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-resources-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
        // The Mini: ten cores, 32 GB.
        server.hostResources = { (10, 32 << 30) }
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ method: String, _ path: String, body: String = "") async -> HTTPResponse {
        let request = HTTPRequest(method: method, path: path, headers: ["authorization": "Bearer pw"], body: body, trusted: false)
        return await withCheckedContinuation { done in
            server.route(request) { done.resume(returning: $0) }
        }
    }

    private func put(_ body: String) async -> HTTPResponse { await call("PUT", "/api/settings", body: body) }

    private func controls(_ response: HTTPResponse) -> ServerControls? {
        parseJSON(response.body).flatMap(ServerControls.init(json:))
    }

    private var kept: ContainerSettings? { ServerSettings.kept(at: VisorServer.settingsURL).container }

    @Test func theAmountsRoundTripAsJSON() throws {
        let change = ServerControlsChange(containerCPUs: .to(10), containerMemoryGiB: .byDefault, containerIdleMinutes: .to(45))
        let json = change.json
        #expect(json["containerCPUs"].int == 10 && json["containerIdleMinutes"].int == 45)
        #expect(json.object?["containerMemoryGiB"] == JSONValue.null, "null for the default")
        #expect(ServerControlsChange(json: try #require(parseJSON(json.encoded()))) == change)
        // Absent is left as it is; "default" is the default too; anything else is kept to be refused.
        let read = ServerControlsChange(json: try #require(parseJSON(#"{"containerMemoryGiB":"default","containerCPUs":2.5}"#)))
        #expect(read.containerMemoryGiB == .byDefault && read.containerIdleMinutes == nil && read.containerEnabled == nil)
        #expect(read.containerCPUs == .unreadable(.number(2.5)))
        #expect(ServerControlsChange(json: try #require(parseJSON(#"{"containerCPUs":"lots"}"#))).containerCPUs == .unreadable(.string("lots")))

        // The settings and the limits, as GET /api/settings says them.
        var controls = ServerControls()
        controls.settings = ServerControls.Settings(containerEnabled: true, containerCPUs: 10, containerMemoryGiB: 24, containerIdleMinutes: 45)
        controls.containerLimits = ServerControls.ContainerLimits(maximumCPUs: 10, defaultCPUs: 8, maximumMemoryGiB: 28, note: "next start")
        #expect(ServerControls(json: try #require(parseJSON(controls.json.encoded()))) == controls)
        let defaults = ServerControls.Settings()
        #expect(defaults.json.object?["containerCPUs"] == JSONValue.null && defaults.json.object?["containerMemoryGiB"] == JSONValue.null)
        #expect(ServerControls.Settings(json: defaults.json) == defaults)
        #expect(ServerControls.Settings(json: .object([:])).containerIdleMinutes == 30, "from a server before them")
    }

    @Test func theLimitsAreThisComputers() throws {
        let limits = try #require(controls(await call("GET", "/api/settings"))?.containerLimits)
        #expect(limits.minimumCPUs == 1 && limits.maximumCPUs == 10 && limits.defaultCPUs == 8)
        #expect(limits.minimumMemoryGiB == 4 && limits.maximumMemoryGiB == 28 && limits.defaultMemoryCapGiB == 24)
        #expect(limits.minimumIdleMinutes == 1 && limits.maximumIdleMinutes == 1440 && limits.defaultIdleMinutes == 30)
        #expect(limits.note.contains("next start") && limits.note.contains("isn't restarted"))
    }

    @Test func cpusAndMemoryAreSetAndKept() async throws {
        let changed = await put(#"{"containerCPUs":10,"containerMemoryGiB":24,"containerIdleMinutes":45}"#)
        #expect(changed.status == 200, "\(changed.body)")
        let now = try #require(controls(changed))
        #expect(now.settings.containerCPUs == 10 && now.settings.containerMemoryGiB == 24 && now.settings.containerIdleMinutes == 45)
        #expect(!now.settings.containerEnabled, "the switch left as it was")
        #expect(kept?.cpus == 10 && kept?.memoryGiB == 24 && kept?.idleMinutes == 45, "kept in the settings file")
        // The least each may be.
        #expect(await put(#"{"containerCPUs":1,"containerMemoryGiB":4,"containerIdleMinutes":1}"#).status == 200)
        #expect(kept?.cpus == 1 && kept?.memoryGiB == 4 && kept?.idleMinutes == 1)
        // The most: all the cores, all the memory less 4 GiB, a day.
        #expect(await put(#"{"containerCPUs":10,"containerMemoryGiB":28,"containerIdleMinutes":1440}"#).status == 200)
        #expect(kept?.cpus == 10 && kept?.memoryGiB == 28 && kept?.idleMinutes == 1440)
    }

    @Test func aValueOutsideTheLimitsIsRefusedNotClamped() async throws {
        #expect(await put(#"{"containerCPUs":6,"containerMemoryGiB":16}"#).status == 200)
        let refusals: [(String, String)] = [
            (#"{"containerCPUs":11}"#, "at most 10 CPUs"),
            (#"{"containerCPUs":0}"#, "at least 1 CPU"),
            (#"{"containerCPUs":-2}"#, "at least 1 CPU"),
            (#"{"containerMemoryGiB":29}"#, "at most 28 GiB"),
            (#"{"containerMemoryGiB":3}"#, "at least 4 GiB"),
            (#"{"containerIdleMinutes":0}"#, "1 to 1440"),
            (#"{"containerIdleMinutes":1441}"#, "1 to 1440"),
            (#"{"containerCPUs":"lots"}"#, "whole number"),
            (#"{"containerMemoryGiB":12.5}"#, "whole number"),
            // One refused, the change as a whole refused: the rest of it isn't taken.
            (#"{"containerEnabled":true,"lan":true,"containerCPUs":4,"containerMemoryGiB":64}"#, "at most 28 GiB"),
        ]
        for (body, reason) in refusals {
            let refused = await put(body)
            #expect(refused.status == 400, "\(body)")
            #expect(parseJSON(refused.body)?["error"].string?.contains(reason) == true, "\(body): \(refused.body)")
        }
        #expect(kept?.cpus == 6 && kept?.memoryGiB == 16 && kept?.enabled == false && kept?.idleMinutes == 30, "nothing changed")
        #expect(server.settings.container?.cpus == 6 && server.settings.container?.memoryGiB == 16 && !server.settings.lan)
    }

    @Test func aSmallComputerTakesNoMemorySetting() async throws {
        server.hostResources = { (4, 6 << 30) }
        let refused = await put(#"{"containerMemoryGiB":4}"#)
        #expect(refused.status == 400 && refused.body.contains("at most 2 GiB"), "\(refused.body)")
        #expect(controls(await call("GET", "/api/settings"))?.containerLimits?.maximumMemoryGiB == 2)
    }

    @Test func nullOrDefaultGoesBackToTheDefault() async throws {
        #expect(await put(#"{"containerCPUs":10,"containerMemoryGiB":24,"containerIdleMinutes":45}"#).status == 200)
        let reset = await put(#"{"containerCPUs":null,"containerMemoryGiB":"default"}"#)
        #expect(reset.status == 200, "\(reset.body)")
        let now = try #require(controls(reset))
        #expect(now.settings.containerCPUs == nil && now.settings.containerMemoryGiB == nil && now.settings.containerIdleMinutes == 45)
        #expect(kept?.cpus == nil && kept?.memoryGiB == nil && kept?.idleMinutes == 45)
        #expect(await put(#"{"containerIdleMinutes":null}"#).status == 200)
        #expect(kept?.idleMinutes == 30)
        // The file says nothing of them once they're the defaults.
        let file = try String(contentsOf: VisorServer.settingsURL, encoding: .utf8)
        #expect(!file.contains("\"cpus\"") && !file.contains("\"memoryGiB\""), "\(file)")
    }

    /// `GET /api/container` says what the engine would start it with, once
    /// it's told of the change (the running container's own until then:
    /// the engine's tests).
    @Test func theContainerSaysTheSetting() async throws {
        server.sessionsContainer = SettingsEngine()
        let before = try #require(parseJSON(await call("GET", "/api/container").body).flatMap(ContainerStatus.init(json:)))
        #expect(before.cpus == 8 && before.memoryGiB == 10, "the defaults: eight, half of what's free")
        #expect(await put(#"{"containerCPUs":10,"containerMemoryGiB":24}"#).status == 200)
        let after = try #require(parseJSON(await call("GET", "/api/container").body).flatMap(ContainerStatus.init(json:)))
        #expect(after.cpus == 10 && after.memoryGiB == 24)
        #expect(await put(#"{"containerCPUs":null,"containerMemoryGiB":null}"#).status == 200)
        let reset = try #require(parseJSON(await call("GET", "/api/container").body).flatMap(ContainerStatus.init(json:)))
        #expect(reset.cpus == 8 && reset.memoryGiB == 10)
    }

    @Test func theRefusalsAreThisComputers() {
        #expect(ContainerSettings.refusal(cpus: 10, cores: 10) == nil)
        #expect(ContainerSettings.refusal(cpus: 11, cores: 10) != nil)
        #expect(ContainerSettings.refusal(memoryGiB: 24, physicalBytes: 32 << 30) == nil)
        #expect(ContainerSettings.refusal(memoryGiB: 28, physicalBytes: 32 << 30) == nil)
        #expect(ContainerSettings.refusal(memoryGiB: 29, physicalBytes: 32 << 30) != nil)
        #expect(ContainerSettings.maximumMemoryGiB(physicalBytes: 16 << 30) == 12)
        #expect(ContainerSettings.refusal(idleMinutes: 30) == nil)
    }
}
}

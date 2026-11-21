// The engine as the container runner reaches it (step 4), against the fake
// backend: a stop on purpose held (Stop, turned off), so its sessions'
// agents wait rather than starting it again, and a restart that isn't;
// the server's ContainerAgent exec'd as agent-wrapper (its conversation,
// its folder, its repositories cloned there, its Claude folder on
// Sessions) and held as a ContainerAgentRun; and the folders it shares.

import Foundation
import Testing
import VisorContainerCore
import VisorContainerRunner
import VisorProtocol
import VisorServer

extension EngineTests {
    @Test func aStopOnPurposeIsHeldAndAStartOrRestartIsNot() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let engine = rig.engine()
        #expect(await engine.start().held == nil)
        let stopped = await engine.stop()
        #expect(stopped.state == .stopped && stopped.held == "it was stopped by hand")
        let started = await engine.start()
        #expect(started.state == .running && started.held == nil, "started again: no longer held")
        let restarted = await engine.restart()
        #expect(restarted.state == .running && restarted.held == nil)
        #expect(await rig.machines.boots.count == 3, "a restart boots again")
        rig.change { $0.enabled = false }
        await engine.configurationChanged()
        #expect(await engine.status().held == "it was turned off in Settings")
    }

    @Test func aContainerAgentIsExecdAsAgentWrapperAndHeldAsARun() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let sessions = rig.root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let engine = rig.engine(sessions: sessions.path)
        let id = "5f0c7a8e-2b1d-4c3e-9f4a-8b7c6d5e4f3a"
        let folder = sessions.path + "/Claude/" + id
        let agent = ContainerAgent(agent: id, session: "a-session", title: "Moved", model: "opus", workingDirectory: folder,
                                   resumeSessionID: "c-1", skipPermissions: true,
                                   sources: [ContainerAgent.Source(repository: "https://github.com/o/r.git", ref: "main", name: "r")],
                                   sourcesDirectory: folder, token: "eyJ.runner.agent",
                                   environment: ["CLAUDE_CONFIG_DIR": sessions.path + "/.claude"])
        let run = try await engine.startAgent(agent)
        let exec = try #require(await rig.machines.last?.execs.last)
        #expect(exec.arguments == ["/opt/visor/bin/agent-wrapper", "--skip-permissions"])
        #expect(exec.workingDirectory == folder)
        #expect(exec.environment["AGENT_ID"] == "\(id)@http://127.0.0.1:7434")
        #expect(exec.environment["AGENT_TOKEN"] == "eyJ.runner.agent")
        #expect(exec.environment["AGENT_SOURCES_DIR"] == folder)
        #expect(exec.environment["CLAUDE_CONFIG_DIR"] == sessions.path + "/.claude")
        #expect(exec.environment["AGENT_DISPATCHER_URL"] == nil, "it reports to no dispatcher: Visor drives it")
        let job = try #require(exec.environment["AGENT_JOB"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(job.utf8)) as? [String: Any])
        #expect(object["resumeSessionID"] as? String == "c-1" && object["workingDirectory"] as? String == folder)
        let sources = try #require(object["sources"] as? [[String: String]])
        #expect(sources == [["repository": "https://github.com/o/r.git", "ref": "main", "name": "r"]])
        #expect(!job.contains("eyJ.runner.agent"))
        await run.signal(15)
        #expect(await run.wait() == 128 + 15)
        _ = await engine.stop()
    }

    @Test func itSharesSessionsAndTheCheckoutsOutsideIt() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let engine = rig.engine(sessions: "/Volumes/Sessions")
        var configuration = rig.configuration.withLock { $0 }
        #expect(engine.sharedFolders(configuration) == ["/Volumes/Sessions"])
        configuration.checkouts = "/Volumes/Work"
        #expect(engine.sharedFolders(configuration) == ["/Volumes/Sessions", "/Volumes/Work"])
        configuration.checkouts = "/Volumes/Sessions/Work"
        #expect(engine.sharedFolders(configuration) == ["/Volumes/Sessions"], "under Sessions: shared with it")
    }
}

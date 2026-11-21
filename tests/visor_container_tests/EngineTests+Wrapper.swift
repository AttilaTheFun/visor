// The container engine's driver link and its agent-wrapper (PR 3), against
// the fake backend: the driver's socket carried in beside the relay's and
// joined on the host to the driver's port with nothing before the guest's
// bytes (no PROXY header), whether or not agent-proxy is there; and
// startWrapper's argv, environment (the runner's AGENT_* contract), working
// folder and log.

import CAgentProxyPOSIX
import Foundation
import Synchronization
import Testing
import VisorContainerCore

extension EngineTests {
    /// A TCP listener on loopback that answers "DRIVER <what it read>" and
    /// closes: a stand-in for Visor's driver. Its port, and how to stop it.
    private func fakeDriver() throws -> (port: Int, stop: @Sendable () -> Void) {
        for _ in 0..<20 {
            let port = Int.random(in: 20000...45000)
            let listener = agent_proxy_listen(UInt16(port), 0)
            guard listener >= 0 else { continue }
            Thread.detachNewThread {
                while true {
                    let stream = agent_proxy_accept(listener)
                    if stream < 0 { return }
                    Thread.detachNewThread {
                        var buffer = [UInt8](repeating: 0, count: 256)
                        let count = buffer.withUnsafeMutableBytes { read(stream, $0.baseAddress, $0.count) }
                        if count > 0 {
                            let answer = Array("DRIVER ".utf8) + buffer[0..<count]
                            _ = answer.withUnsafeBytes { write(stream, $0.baseAddress, $0.count) }
                        }
                        close(stream)
                    }
                }
            }
            return (port, { agent_proxy_shutdown(listener); close(listener) })
        }
        throw FakeDriverError()
    }

    private struct FakeDriverError: Error {}

    /// What the Unix socket at `path` answers `text` with, read to its end.
    private func ask(_ path: String, _ text: String) -> String {
        let socket = agent_proxy_connect_unix(path)
        guard socket >= 0 else { return "(no socket)" }
        defer { close(socket) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        var heard: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            heard += buffer[0..<count]
        }
        return String(decoding: heard, as: UTF8.self)
    }

    @Test func theDriverLinkJoinsTheGuestToTheDriverWithNoHeaderAndNoAgentProxy() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let driver = try fakeDriver()
        defer { driver.stop() }
        let engine = rig.engine(driverPort: driver.port)
        let status = await engine.start()
        #expect(status.state == .running, "\(status.errors)")
        let socket = rig.socketFolder.appendingPathComponent("driver.sock").path
        #expect(engine.context.driverSocket.path == socket, "beside the relay's, in the same folder")
        // The guest's bytes first and alone: the agents' JWTs, not a PROXY
        // header, say who they are.
        #expect(ask(socket, "PRI * HTTP/2.0") == "DRIVER PRI * HTTP/2.0")
        #expect(ask(socket, "again") == "DRIVER again", "each connection its own")
        // No agent-proxy at the relay's port here: the relay closes, the
        // driver link doesn't care.
        #expect(ask(rig.socketFolder.appendingPathComponent("relay.sock").path, "GET / HTTP/1.1\r\n\r\n") == "")
        #expect(ask(socket, "still") == "DRIVER still")
        _ = await engine.stop()
        #expect(!FileManager.default.fileExists(atPath: socket), "stopped with the container")
    }

    @Test func noDriverAnsweringClosesTheGuestsConnection() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let driver = try fakeDriver()
        driver.stop()
        let lines = Mutex<[String]>([])
        let link = UnixBridge(name: "driver link", target: "Visor's driver", socketPath: rig.socketFolder.appendingPathComponent("d.sock").path,
                              port: driver.port, opening: { .plain }, log: { line in lines.withLock { $0.append(line) } })
        try link.start()
        defer { link.stop() }
        #expect(ask(link.socketPath, "hello") == "")
        #expect(lines.withLock { $0.contains { $0.contains("driver link: Visor's driver at 127.0.0.1:\(driver.port) didn't answer") } })
    }

    @Test func startWrapperExecsAgentWrapperWithTheRunnersEnvironment() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let sessions = rig.root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let engine = rig.engine(sessions: sessions.path)
        let id = "0d6b1c1e-4f7a-4a43-9a51-6f1b8a3e2c11"
        let folder = sessions.path + "/Claude/" + id
        let session = ContainerSession(
            id: id, dispatcherURL: "http://127.0.0.1:7434", title: "A task", prompt: "Start here", model: "opus", workingDirectory: folder,
            labels: ["container"], token: "eyJ.agent.jwt",
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "oauth", "AGENT_TOKEN": "not this one", "AGENT_DRIVER_URL": "http://elsewhere:1"])
        let execution = try await engine.startWrapper(session: session)
        #expect(execution.id == id)
        #expect(execution.log == rig.layout.log(process: id), "logs/<session>.log")
        #expect(FileManager.default.fileExists(atPath: folder), "its folder made on the Mac, seen at the same path in the guest")
        let machine = try #require(await rig.machines.last)
        let exec = try #require(await machine.execs.last)
        #expect(exec.arguments == ["/opt/visor/bin/agent-wrapper", "--skip-permissions"])
        #expect(exec.workingDirectory == folder)
        var environment = exec.environment
        let removed = environment.removeValue(forKey: "AGENT_JOB")
        let job = try #require(removed)
        #expect(environment == [
            "AGENT_ID": "\(id)@http://127.0.0.1:7434",
            "AGENT_DRIVER_URL": "http://127.0.0.1:7434",
            "AGENT_RUNNER": "visor-sessions",
            "AGENT_SESSIONS_DIR": sessions.path,
            "AGENT_TOKEN": "eyJ.agent.jwt",
            "CLAUDE_CODE_OAUTH_TOKEN": "oauth",
            "HOME": "/root",
            "TMPDIR": "/tmp",
        ])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(job.utf8)) as? [String: Any])
        #expect(object["agent"] as? String == id)
        #expect(object["dispatcherURL"] as? String == "http://127.0.0.1:7434")
        #expect(object["driverURL"] as? String == "http://127.0.0.1:7434")
        #expect(object["workingDirectory"] as? String == folder)
        #expect(object["title"] as? String == "A task" && object["prompt"] as? String == "Start here" && object["model"] as? String == "opus")
        #expect(object["labels"] as? [String] == ["container"])
        #expect(object["skipPermissions"] == nil, "the job doesn't say")
        #expect(object["harness"] == nil && object["resumeSessionID"] == nil)
        #expect(!job.contains("eyJ.agent.jwt"), "the token is in AGENT_TOKEN alone")
        #expect(await engine.running.contains(id))
        try await execution.signal(15)
        #expect(await execution.wait() == 128 + 15)
        _ = await engine.stop()
    }

    @Test func theWrappersFlagsFolderAndOptionalVariables() throws {
        let base = ContainerSession(id: "a1", dispatcherURL: "http://d")
        let asks = ContainerEngine.wrapperExec(with(base) { $0.skipPermissions = false }, sessions: "/Volumes/Sessions")
        #expect(asks.arguments == ["/opt/visor/bin/agent-wrapper"], "a job that asks: no --skip-permissions")
        #expect(asks.environment["AGENT_JOB"]?.contains("\"skipPermissions\":false") == true)
        let acts = ContainerEngine.wrapperExec(with(base) { $0.skipPermissions = true }, sessions: "/Volumes/Sessions")
        #expect(acts.arguments == ["/opt/visor/bin/agent-wrapper", "--skip-permissions"])
        #expect(acts.environment["AGENT_JOB"]?.contains("\"skipPermissions\":true") == true)

        let plain = ContainerEngine.wrapperExec(base, sessions: "/Volumes/Sessions")
        #expect(plain.workingDirectory == nil, "no folder: the wrapper's own, <Sessions>/Claude/<id>")
        for absent in ["AGENT_DISPATCHER_URL", "AGENT_TOKEN", "AGENT_SOURCES_DIR", "AGENT_WRAPPER_CLAUDE"] {
            #expect(plain.environment[absent] == nil, "\(absent)")
        }
        #expect(ContainerEngine.wrapperExec(with(base) { $0.token = "" }, sessions: "/Volumes/Sessions").environment["AGENT_TOKEN"] == nil)

        let full = ContainerEngine.wrapperExec(with(base) {
            $0.reportsTo = "http://127.0.0.1:7434"
            $0.sourcesDirectory = "/Volumes/Work"
            $0.claudeProgram = "/Volumes/Sessions/fake-claude.py"
            $0.harness = "echo"
            $0.resumeSessionID = "s-1"
            $0.runner = "the-mini"
        }, sessions: "/Volumes/Sessions")
        #expect(full.environment["AGENT_DISPATCHER_URL"] == "http://127.0.0.1:7434")
        #expect(full.environment["AGENT_SOURCES_DIR"] == "/Volumes/Work")
        #expect(full.environment["AGENT_WRAPPER_CLAUDE"] == "/Volumes/Sessions/fake-claude.py")
        #expect(full.environment["AGENT_RUNNER"] == "the-mini")
        let job = try #require(full.environment["AGENT_JOB"])
        #expect(job.contains("\"harness\":\"echo\"") && job.contains("\"resumeSessionID\":\"s-1\""))

        // The exec's folder only where the guest sees it at the same path.
        let folder = { (path: String) in ContainerEngine.wrapperExec(with(base) { $0.workingDirectory = path }, sessions: "/Volumes/Sessions",
                                                                     checkouts: "/Volumes/Work").workingDirectory }
        #expect(folder("/Volumes/Sessions/Claude/a1") == "/Volumes/Sessions/Claude/a1")
        #expect(folder("/Volumes/Work/visor") == "/Volumes/Work/visor")
        #expect(folder("/Users/someone/project") == nil, "not shared in")
        #expect(folder("/Volumes/SessionsElsewhere/x") == nil)
        #expect(folder("/Volumes/Sessions/../etc") == nil)
        #expect(folder("relative/path") == nil)
    }

    private func with(_ session: ContainerSession, _ edit: (inout ContainerSession) -> Void) -> ContainerSession {
        var changed = session
        edit(&changed)
        return changed
    }
}

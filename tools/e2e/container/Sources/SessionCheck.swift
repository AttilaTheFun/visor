// The real session check (the container runner, step 4): a Visor server of
// this run's own, on a throwaway data folder and Claude folder (in /tmp),
// its secrets in memory, never listening for clients, with its
// agent_protocol driver on a free loopback port (never the installed
// server's 7434), given the booted container as its Sessions container
// (E2EContainer). Then, as a session in it would go:
//
// 1. A new session in the container: its agent-wrapper (with the stand-in
//    claude) started by the server's container runner, with its own token,
//    connects through the driver link to the real driver, and is running.
// 2. Its first message answered ("echo: …"), its rows the server's.
// 3. Its conversation kept on Sessions, where the host reads it: the
//    container's Claude folder (CLAUDE_CONFIG_DIR) is on the shared volume.
// 4. The container restarted under it (as an update of its image does):
//    the runner starts its next agent there, on the same conversation.
// 5. Move Back hands its conversation back (DriverMessage.hand_back,
//    ReturnConversation): back on this computer, the conversation under
//    this computer's Claude folder (the run's), with what was said in the
//    container in it.
// 6. Its agent in the container ended.
//
// The server can't start an agent on this Mac (its harness's tool is one
// that isn't there), so the session back here starts nothing.

import ClaudeTranscript
import Foundation
import VisorAgent
import VisorContainerCore
import VisorDriver
import VisorProtocol
import VisorServer
import VisorServerApple
import VisorSystem

@MainActor
struct SessionCheck {
    let server: VisorServer
    let driver: VisorDriver.Listening
    let scratch: Scratch

    /// The run's own server, on `scratch`, its driver on loopback `port`.
    static func make(scratch: Scratch, port: Int) -> SessionCheck {
        let data = scratch.root.appendingPathComponent("server", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        HostFolders.dataRoot = data
        ClaudeSessionFiles.home = scratch.root.appendingPathComponent("home", isDirectory: true)
        var platform = ServerPlatform.apple(secrets: MemorySecrets())
        platform.host.dataDirectory = data
        platform.log = { ContainerCheck.say("server: \($0)") }
        ServerPlatform.current = platform
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = scratch.root.appendingPathComponent("visor.sock").path
        let server = VisorServer(port: UInt16(port + 1))
        server.harnesses = AgentHarnesses([ClaudeHarness(kind: .claude, tool: "visor-e2e-no-claude", models: [])])
        let driver = VisorDriver.Listening(host: "127.0.0.1", port: port, url: "http://127.0.0.1:\(port)")
        driver.serve(server)
        return SessionCheck(server: server, driver: driver, scratch: scratch)
    }

    /// The checks, in order, with `container` its Sessions container: each
    /// one's name and whether it passed.
    func run(_ container: E2EContainer) async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func record(_ name: String, _ ok: Bool) { results.append((name, ok)) }
        server.sessionsContainer = container
        let prompt = "hello from the e2e \(scratch.id)"
        let started = await server.startSessionInContainer(title: "e2e \(scratch.id)", prompt: prompt)
        guard case .success(let id) = started, let session = server.session(id) else {
            if case .failure(let refusal) = started { record("a session started in the container: \(refusal.reason)", false) }
            return results
        }
        let firstAgent = session.move?.agent ?? ""
        let running = await Self.within(seconds: 120) { session.info.agentState == .running }
        record("a session started in the container: its agent connects through the driver link, with its own token (running)", running)
        let answered = await Self.within(seconds: 60) { session.entries.contains { $0.text.contains("echo: \(prompt)") } }
        record("its first message answered through the driver (echo: …)", answered)

        let conversation = session.move?.conversation ?? ""
        let key = ClaudeSessionFiles.projectDirectoryName(for: session.info.cwd)
        let onSessions = scratch.sessions.appendingPathComponent(".claude/projects/\(key)/\(conversation).jsonl")
        let kept = (try? String(contentsOf: onSessions, encoding: .utf8)) ?? ""
        record("its conversation (\(conversation.isEmpty ? "none said" : conversation)) kept on Sessions, read from the host",
               !conversation.isEmpty && kept.contains("echo: \(prompt)"))

        let restarted = await container.restart()
        let again = await Self.within(seconds: 180) {
            session.info.agentState == .running && (session.move?.agent ?? firstAgent) != firstAgent
        }
        record("the container restarted (\(restarted.state.rawValue)): its next agent started there, running again", again)
        record("on the same conversation", session.move?.conversation == conversation && !conversation.isEmpty)

        let agent = session.move?.agent ?? ""
        let moved = server.moveBack(id, resume: conversation, cwd: "", why: "the e2e moved it back", loud: false)
        if case .failure(let refusal) = moved { record("Move Back: \(refusal.reason)", false) }
        await server.handBackEnded(id)
        let here = ClaudeSessionFiles.projectsRoot().appendingPathComponent(key).appendingPathComponent("\(conversation).jsonl")
        let returned = (try? String(contentsOf: here, encoding: .utf8)) ?? ""
        record("Move Back hands its conversation back: on this computer, its transcript under this computer's Claude folder",
               !session.driven && returned.contains("echo: \(prompt)"))
        let ended = await Self.within(seconds: 60) { await !container.engine.running.contains(agent) }
        record("its agent in the container ended", ended)
        return results
    }

    /// Whether `condition` holds within `seconds`.
    static func within(seconds: Int, _ condition: () async -> Bool) async -> Bool {
        for _ in 0..<(seconds * 4) {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}

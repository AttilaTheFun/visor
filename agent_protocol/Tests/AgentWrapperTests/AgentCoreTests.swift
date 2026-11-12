// One agent under a stand-in harness: its prompt sent, its words and tool
// calls as rows, busy while it works, a message sent meanwhile waiting for
// the turn's end, and its end told.

import AgentProtocol
import AgentWrapper
import XCTest

final class AgentCoreTests: XCTestCase {
    private func core(prompt: String = "") -> AgentCore {
        var spec = AgentProtocol_V1_AgentSpec()
        spec.harness = "claude"
        spec.prompt = prompt
        spec.workingDirectory = FileManager.default.temporaryDirectory.path
        var agent = AgentProtocol_V1_AgentID()
        agent.uuid = "a1"
        agent.dispatcherURL = "http://dispatcher"
        return AgentCore(agent: agent, spec: spec, launch: HarnessLaunch(executable: FakeClaude.path, arguments: []))
    }

    /// Until `condition` holds of the core, or 10 s.
    private func until(_ core: AgentCore, _ condition: @escaping @Sendable (AgentCore) async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition(core) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("not in time")
    }

    func testThePromptIsAnsweredAndAMessageMeanwhileWaitsItsTurn() async throws {
        let agent = core(prompt: "first")
        try await agent.start()
        let queued = await agent.send(id: "m2", text: "second")
        XCTAssertTrue(queued, "it works on the prompt meanwhile")
        try await until(agent) { core in
            let answers = await core.entries.filter { $0.role == .assistant && !$0.text.isEmpty }.count
            let busy = await core.state.busy
            return answers == 2 && !busy
        }
        let words = await agent.entries.map { "\($0.role == .user ? "user" : "agent"): \($0.text.isEmpty ? $0.activities.joined() : $0.text)" }
        XCTAssertEqual(words, ["user: first", "agent: Bash: true", "agent: echo: first", "user: second", "agent: Bash: true", "agent: echo: second"])
        let session = await agent.sessionID
        XCTAssertEqual(session, "fake-session")
        let state = await agent.state
        XCTAssertEqual(state.model, "fake-model")
        XCTAssertTrue(state.queued.isEmpty)
        XCTAssertTrue(state.tools.isEmpty)
        await agent.stop(grace: .milliseconds(200))
        let why = await agent.ended()
        XCTAssertTrue(why.hasPrefix("the harness ended"), why)
    }

    func testAMessageSentTwiceIsTakenOnce() async throws {
        let agent = core()
        try await agent.start()
        await agent.send(id: "same", text: "once")
        await agent.send(id: "same", text: "once")
        try await until(agent) { core in
            let busy = await core.state.busy
            let answered = await core.entries.contains { $0.text == "echo: once" }
            return !busy && answered
        }
        let users = await agent.entries.filter { $0.role == .user }.count
        XCTAssertEqual(users, 1)
        await agent.stop(grace: .milliseconds(200))
    }
}

// A driven session's process (VisorDriver): what the session sends goes
// down the wrapper's stream, held while no wrapper is connected; what the
// wrapper says comes up as a harness's events, a turn's end last. A wrapper
// that said protocol 2 takes a hand-back, whose end is no failure.

import AgentProtocol
@testable import VisorAgent
@testable import VisorDriver
import VisorProtocol
import Foundation
import Testing

@Suite @MainActor final class DrivenProcessTests {
    /// The first `count` events `process` gave for `messages` (each is
    /// given as the message is taken, so they wait in the stream).
    private func events(of process: DrivenProcess, after messages: [AgentProtocol_V1_WrapperMessage], count: Int) async -> [String] {
        for message in messages { process.take(message) }
        var said: [String] = []
        var iterator = process.events.makeAsyncIterator()
        while said.count < count, let event = await iterator.next() { said.append(Self.describe(event)) }
        return said
    }

    static func describe(_ event: AgentEvent) -> String {
        switch event {
        case .rows(let rows): "rows " + rows.map { "\($0.role.rawValue):\($0.text.isEmpty ? $0.activities.joined() : $0.text)" }.joined(separator: ",")
        case .busy(let busy): "busy \(busy)"
        case .thinking(let on): "thinking \(on)"
        case .toolStarted(_, let name, _, _): "tool \(name)"
        case .toolFinished: "tool done"
        case .activity(let label): "activity \(label ?? "-")"
        case .model(let model): "model \(model)"
        case .failure(let text): "failure \(text)"
        case .turnBegan: "began"
        default: "other"
        }
    }

    @Test func testWhatTheWrapperSaysComesUpAsAHarnesssEvents() async {
        let process = DrivenProcess()
        var working = AgentProtocol_V1_EphemeralState()
        working.busy = true
        working.model = "claude-opus"
        working.tools = [.with { $0.id = "t1"; $0.name = "Bash"; $0.label = "Bash: ls" }]
        working.activity = "Bash: ls"
        let messages: [AgentProtocol_V1_WrapperMessage] = [
            .with { $0.state = working },
            .with { $0.entries = .with { $0.entries = [.with { $0.id = "r1"; $0.role = .assistant; $0.text = "Hello" }] } },
            .with { $0.state = .init() },
        ]
        // A turn the wrapper says is running has begun: no longer sending.
        let said = await events(of: process, after: messages, count: 9)
        #expect(said == ["tool Bash", "activity Bash: ls", "model claude-opus", "busy true", "began", "rows assistant:Hello",
                              "tool done", "activity -", "busy false"])
    }

    @Test func testWhatIsSentWaitsForAWrapperThenGoesDown() throws {
        let process = DrivenProcess()
        try process.send("first")
        process.interrupt()
        var down: [AgentProtocol_V1_DriverMessage] = []
        let connection = process.attach { down.append($0) }
        #expect(down.count == 2, "what waited, in order")
        #expect((down.first?.send.text) == "first")
        try process.send("second")
        #expect((down.last?.send.text) == "second")
        process.detach(connection)
        try process.send("third")
        #expect(down.count == 3, "held again once the wrapper is gone")
    }

    /// A prompt with nothing to show of its input (an MCP tool that takes
    /// none, pilot 2's Shireworks `status`) names its tool, not a blank line.
    @Test func testAPromptWithNoInputNamesItsTool() {
        let status = DrivenProcess.prompt(.with { $0.id = "p1"; $0.tool = "mcp__shireworks__status"; $0.inputJson = "{}" })
        #expect(status.summary == "shireworks › status")
        let other = DrivenProcess.prompt(.with { $0.id = "p2"; $0.tool = "Tidy"; $0.inputJson = "{}" })
        #expect(other.summary == "Tidy")
        let given = DrivenProcess.prompt(.with { $0.id = "p3"; $0.tool = "mcp__shireworks__lease"; $0.summary = "mac"; $0.inputJson = "{}" })
        #expect(given.summary == "mac", "the wrapper's own line, when it has one")
    }

    /// The wrapper's permission prompts (agent_protocol#10): each shown
    /// once as the session's pending approval, however often it is asked;
    /// the person's answer down to the wrapper, once, and again to a wrapper
    /// that asks again (its answer lost with a connection); withdrawn, or
    /// gone with the connection, no longer shown.
    @Test func testAWrappersApprovalsAreTheSessionsAndItsAnswersGoBack() async {
        let process = DrivenProcess()
        var down: [AgentProtocol_V1_DriverMessage] = []
        let connection = process.attach { down.append($0) }
        let bash = AgentProtocol_V1_WrapperMessage.with { $0.approval = .with {
            $0.id = "p1"; $0.tool = "Bash"; $0.summary = "ls -la"; $0.inputJson = #"{"command":"ls -la"}"#; $0.toolUseID = "tu1"
        } }
        let question = AgentProtocol_V1_WrapperMessage.with { $0.approval = .with {
            $0.id = "p2"; $0.tool = "AskUserQuestion"
            $0.inputJson = #"{"questions":[{"question":"Which one?","header":"Pick","options":[{"label":"A","description":"a"},{"label":"B"}],"multiSelect":false}]}"#
        } }
        let shown = await prompts(of: process, after: [bash, bash, question, .with { $0.approvalWithdrawn = "p9" }], count: 2)
        #expect(shown.map(\.id) == ["p1", "p2"], "each once, a withdrawal of nothing nothing")
        #expect(shown.first == ApprovalRequest(id: "p1", tool: "Bash", summary: "ls -la"))
        #expect((shown.last?.questions?.first?.question) == "Which one?")
        #expect((shown.last?.questions?.first?.options.map(\.label)) == ["A", "B"])
        #expect((shown.last?.summary) == "Which one?")

        #expect(process.decide("p1", allow: true, answers: nil))
        #expect(!process.decide("p1", allow: true, answers: nil), "answered once")
        #expect(!process.decide("nobody", allow: false, answers: nil))
        #expect((down.last?.approval) == .with { $0.requestID = "p1"; $0.allow = true })
        #expect(process.decide("p2", allow: true, answers: ["Which one?": "B"]))
        let answered = parseJSON(down.last?.approval.updatedInputJson ?? "")
        #expect((answered?["answers"]["Which one?"].string) == "B")
        #expect((answered?["questions"][0]["question"].string) == "Which one?", "the input as asked, with its answers")

        // Asked again (a reconnect lost the answer): answered again, not shown.
        process.take(bash)
        #expect((down.last?.approval) == .with { $0.requestID = "p1"; $0.allow = true })
        #expect(down.count == 3)

        let edit = AgentProtocol_V1_WrapperMessage.with { $0.approval = .with { $0.id = "p3"; $0.tool = "Edit"; $0.summary = "/a" } }
        _ = await prompts(of: process, after: [edit], count: 1)
        #expect(process.decide("p3", allow: false, answers: nil))
        #expect((down.last?.approval) == .with { $0.requestID = "p3"; $0.reason = "The user denied this from Visor." })

        // Withdrawn by the agent, or gone with its connection: no longer shown.
        let write = AgentProtocol_V1_WrapperMessage.with { $0.approval = .with { $0.id = "p4"; $0.tool = "Write" } }
        let read = AgentProtocol_V1_WrapperMessage.with { $0.approval = .with { $0.id = "p5"; $0.tool = "Read" } }
        let events = await withdrawals(of: process, after: [write, .with { $0.approvalWithdrawn = "p4" }, read]) { process.detach(connection) }
        #expect(events == ["asked p4", "withdrawn p4", "asked p5", "withdrawn p5"])
        #expect(!process.decide("p5", allow: true, answers: nil), "gone with its connection: asked again on the next")
    }

    /// The prompts `process` showed for `messages`, the first `count`.
    private func prompts(of process: DrivenProcess, after messages: [AgentProtocol_V1_WrapperMessage], count: Int) async -> [ApprovalRequest] {
        for message in messages { process.take(message) }
        var shown: [ApprovalRequest] = []
        var iterator = process.events.makeAsyncIterator()
        while shown.count < count, let event = await iterator.next() {
            if case .question(let request) = event { shown.append(request) }
        }
        return shown
    }

    /// What `process` said of its prompts, asked and withdrawn, for
    /// `messages` and then `then`.
    private func withdrawals(of process: DrivenProcess, after messages: [AgentProtocol_V1_WrapperMessage],
                             then: () -> Void) async -> [String] {
        for message in messages { process.take(message) }
        then()
        var said: [String] = []
        var iterator = process.events.makeAsyncIterator()
        while said.count < 4, let event = await iterator.next() {
            switch event {
            case .question(let request): said.append("asked \(request.id)")
            case .withdrawn(let id): said.append("withdrawn \(id)")
            default: break
            }
        }
        return said
    }

    @Test func testAProtocolTwoWrapperTakesAHandBackWhoseEndIsNoFailure() async {
        let process = DrivenProcess()
        #expect(!process.takesHandBack, "no hello yet")
        process.wrapperProtocol = 1
        #expect(!process.takesHandBack, "an older wrapper is told to stop")
        process.wrapperProtocol = 2
        #expect(process.takesHandBack)
        process.handBack()
        var down: [AgentProtocol_V1_DriverMessage] = []
        _ = process.attach { down.append($0) }
        #expect(down.count == 1 && { if case .handBack = down[0].message { true } else { false } }(), "held for its wrapper, then sent")
        let said = await events(of: process, after: [.with { $0.state = .with { $0.busy = true } }, .with { $0.ended = "the harness ended" },
                                                     .with { $0.state = .with { $0.busy = true } }], count: 5)
        #expect(said == ["busy true", "began", "busy false", "busy true", "began"], "its end told as idle, never as a failure")
    }

    @Test func testAWrappersRowBecomesVisorsRow() {
        let row = DrivenProcess.row(.with { $0.id = "u1"; $0.role = .user; $0.text = "Hi"; $0.activities = ["a"] })
        #expect(row == TranscriptEntry(id: "u1", role: .user, text: "Hi", activities: ["a"]))
    }
}

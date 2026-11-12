// A driven session's process (VisorDriver): what the session sends goes
// down the wrapper's stream, held while no wrapper is connected; what the
// wrapper says comes up as a harness's events, a turn's end last.

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
        let said = await events(of: process, after: messages, count: 8)
        #expect(said == ["tool Bash", "activity Bash: ls", "model claude-opus", "busy true", "rows assistant:Hello",
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

    @Test func testAWrappersRowBecomesVisorsRow() {
        let row = DrivenProcess.row(.with { $0.id = "u1"; $0.role = .user; $0.text = "Hi"; $0.activities = ["a"] })
        #expect(row == TranscriptEntry(id: "u1", role: .user, text: "Hi", activities: ["a"]))
    }
}

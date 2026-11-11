// The v2 wire of docs/runners.md: a wrapped agent's and a runner's hellos, a
// runner's start, a queue entry and an agent's report, each read back as
// written; what is missing or of another type refused; what a newer build
// adds read as a default; and which runner a queue entry fits.

import Foundation
import VisorProtocol
import XCTest

final class RunnerWireTests: XCTestCase {
    private func reread(_ json: JSONValue) -> JSONValue {
        parseJSON(json.encoded()) ?? .null
    }

    func testAnAgentsHelloReadsBackAsWritten() throws {
        let hello = AgentHello(session: "abc", agent: .claude, cwd: "/Volumes/Sessions/Claude/abc", title: "Issue 12",
                               runner: "shireworks-mini", links: ["https://github.com/AttilaTheFun/visor/issues/12"], place: .container)
        XCTAssertEqual(AgentHello(json: reread(hello.json)), hello)
        XCTAssertNil(AgentHello(json: reread(RunnerHello(id: "r", name: "r", kind: .native, agents: [.claude], capacity: 1).json)),
                     "a runner's hello is not an agent's")
        XCTAssertNil(AgentHello(json: .object(["type": .string("agent"), "session": .string("")])), "a session is needed")
    }

    func testARunnersHelloLeavesOutAgentsItDoesntKnow() throws {
        let hello = RunnerHello(id: "macbook", name: "MacBook", kind: .native, agents: [.claude, .codex], capacity: 3, running: 1,
                                labels: ["macbook"])
        XCTAssertEqual(RunnerHello(json: reread(hello.json)), hello)
        var json = hello.json
        if case .object(var object) = json {
            object["agents"] = .array([.string("claude"), .string("someday")])
            json = .object(object)
        }
        XCTAssertEqual(RunnerHello(json: json)?.agents, [.claude])
    }

    func testAStartCarriesNoSignInAndReadsBack() throws {
        let start = RunnerStart(session: "abc", agentToken: "t", agent: .codex, repository: "AttilaTheFun/visor", branch: "main",
                                prompt: "Fix #12", title: "Issue 12", links: ["https://github.com/AttilaTheFun/visor/issues/12"])
        XCTAssertEqual(RunnerStart(json: reread(start.json)), start)
        XCTAssertNil(start.json["signIns"].object)
        XCTAssertNil(start.json["cwd"].string, "what isn't given isn't written")
        let resumed = RunnerStart(session: "abc", agentToken: "t", agent: .claude, cwd: "/Users/logan/Developer", title: "Old", resume: "conv-1")
        XCTAssertEqual(RunnerStart(json: reread(resumed.json))?.resume, "conv-1")
    }

    func testAQueueEntryReadsBackAndTakesDefaultsForWhatItDoesntKnow() throws {
        let entry = QueueEntry(id: "abc", agent: .claude, title: "Issue 12", prompt: "Fix it", repository: "AttilaTheFun/visor",
                               labels: ["container"], links: ["https://github.com/AttilaTheFun/visor/issues/12"], archiveWhen: .complete,
                               createdBy: "client:logan", created: Date(timeIntervalSince1970: 1_800_000_000), state: .starting)
        XCTAssertEqual(QueueEntry(json: reread(entry.json)), entry)
        var json = entry.json
        if case .object(var object) = json {
            object["state"] = .string("teleporting")
            object["archiveWhen"] = .string("eventually")
            json = .object(object)
        }
        let read = try XCTUnwrap(QueueEntry(json: json))
        XCTAssertEqual(read.state, .waiting)
        XCTAssertEqual(read.archiveWhen, .never)
    }

    func testAnEntryFitsTheRunnerItNamesOrOneWithEveryLabel() {
        let shireworks = RunnerHello(id: "mini", name: "Shireworks", kind: .container, agents: [.claude], capacity: 2,
                                     labels: ["container", "shireworks"])
        let macbook = RunnerHello(id: "macbook", name: "MacBook", kind: .native, agents: [.claude, .codex], capacity: 1, labels: ["macbook"])
        let date = Date(timeIntervalSince1970: 0)
        let byLabel = QueueEntry(id: "1", agent: .claude, title: "", labels: ["container"], createdBy: "c", created: date)
        XCTAssertTrue(byLabel.fits(shireworks))
        XCTAssertFalse(byLabel.fits(macbook))
        let named = QueueEntry(id: "2", agent: .claude, title: "", runner: "macbook", createdBy: "c", created: date)
        XCTAssertTrue(named.fits(macbook))
        XCTAssertFalse(named.fits(shireworks))
        let codex = QueueEntry(id: "3", agent: .codex, title: "", labels: ["container"], createdBy: "c", created: date)
        XCTAssertFalse(codex.fits(shireworks), "not an agent it runs")
        var full = shireworks
        full.capacity = 0
        XCTAssertFalse(byLabel.fits(full), "no room")
    }

    func testAReportReadsBack() {
        let blocked = AgentReport(session: "abc", kind: .blocked, summary: "The pull request touches .github/",
                                  pullRequest: "https://github.com/AttilaTheFun/visor/pull/350", reason: .codeReview,
                                  at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(AgentReport(json: reread(blocked.json)), blocked)
        XCTAssertEqual(blocked.json["reason"].string, "code_review", "the MCP tool's word for it")
        let complete = AgentReport(session: "abc", kind: .complete, summary: "Fixed and merged", pullRequest: "https://github.com/x/y/pull/1",
                                   merged: true, at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(AgentReport(json: reread(complete.json))?.merged, true)
        let progress = AgentReport(session: "abc", kind: .progress, summary: "Running the tests", step: "tests",
                                   at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(AgentReport(json: reread(progress.json)), progress)
        XCTAssertNil(AgentReport(json: .object(["type": .string("report"), "session": .string("abc"), "kind": .string("shrug"),
                                                "at": .number(0)])))
    }
}

// The v2 wire of docs/runners.md: a wrapped agent's and a runner's hellos, a
// queue entry, a runner's claim and update, and an agent's report, each read
// back as written; what is missing or of another type refused; what a newer
// build adds read as a default; and which runner may claim an entry, a lapsed
// lease's included.

import Foundation
import VisorProtocol
import Testing

extension ServerTests {
@Suite final class RunnerWireTests {
    private func reread(_ json: JSONValue) -> JSONValue {
        parseJSON(json.encoded()) ?? .null
    }

    @Test func testAnAgentsHelloReadsBackAsWritten() throws {
        let hello = AgentHello(session: "abc", agent: .claude, cwd: "/Volumes/Sessions/Claude/abc", title: "Issue 12",
                               runner: "shireworks-mini", links: ["https://github.com/AttilaTheFun/visor/issues/12"], place: .container)
        #expect((AgentHello(json: reread(hello.json))) == hello)
        #expect((hello.json["protocol"].int) == 2, "the runner protocol's version, said in every hello")
        #expect((AgentHello(json: reread(RunnerHello(id: "r", name: "r", kind: .native, agents: [.claude], capacity: 1).json))) == nil, "a runner's hello is not an agent's")
        #expect((AgentHello(json: .object(["type": .string("agent"), "session": .string("")]))) == nil, "a session is needed")
    }

    @Test func testARunnersHelloLeavesOutAgentsItDoesntKnow() throws {
        let hello = RunnerHello(id: "macbook", name: "MacBook", kind: .native, agents: [.claude, .codex], capacity: 3, running: 1,
                                labels: ["macbook"], sessions: ["abc": "/Users/logan/Developer/visor"])
        #expect((RunnerHello(json: reread(hello.json))) == hello)
        #expect((RunnerHello(json: reread(hello.json))?.protocolVersion) == 2)
        var json = hello.json
        if case .object(var object) = json {
            object["agents"] = .array([.string("claude"), .string("someday")])
            json = .object(object)
        }
        #expect((RunnerHello(json: json)?.agents) == [.claude])
    }

    @Test func testAQueueEntryReadsBackAndTakesDefaultsForWhatItDoesntKnow() throws {
        let entry = QueueEntry(id: "e1", session: "abc", agent: .claude, title: "Issue 12", prompt: "Fix it",
                               repository: "AttilaTheFun/visor", labels: ["container"],
                               links: ["https://github.com/AttilaTheFun/visor/issues/12"], archiveWhen: .complete, createdBy: "client:logan",
                               created: Date(timeIntervalSince1970: 1_800_000_000), state: .claimed, claimedBy: "mini",
                               leaseExpires: Date(timeIntervalSince1970: 1_800_000_060))
        #expect((QueueEntry(json: reread(entry.json))) == entry)
        var json = entry.json
        if case .object(var object) = json {
            object["state"] = .string("teleporting")
            object["archiveWhen"] = .string("eventually")
            json = .object(object)
        }
        let read = try #require(QueueEntry(json: json))
        #expect(read.state == .waiting)
        #expect(read.archiveWhen == .never)
        if case .object(var object) = entry.json {
            object["kind"] = .string("defragment")
            #expect((QueueEntry(json: .object(object))) == nil, "a job this build can't carry out isn't read")
        }
    }

    @Test func testAnEntryIsClaimableByTheRunnerItNamesOrOneWithEveryLabelOnceItsLeaseLapses() {
        let shireworks = RunnerHello(id: "mini", name: "Shireworks", kind: .container, agents: [.claude], capacity: 2,
                                     labels: ["container", "shireworks"])
        let macbook = RunnerHello(id: "macbook", name: "MacBook", kind: .native, agents: [.claude, .codex], capacity: 1, labels: ["macbook"])
        let now = Date(timeIntervalSince1970: 1_000)
        let byLabel = QueueEntry(id: "1", session: "s1", agent: .claude, title: "", labels: ["container"], createdBy: "c", created: now)
        #expect(byLabel.claimable(by: shireworks, at: now))
        #expect(!byLabel.claimable(by: macbook, at: now))
        let named = QueueEntry(id: "2", session: "s2", agent: .claude, title: "", runner: "macbook", createdBy: "c", created: now)
        #expect(named.claimable(by: macbook, at: now))
        #expect(!named.claimable(by: shireworks, at: now))
        let codex = QueueEntry(id: "3", session: "s3", agent: .codex, title: "", labels: ["container"], createdBy: "c", created: now)
        #expect(!codex.claimable(by: shireworks, at: now), "not an agent it runs")
        var full = shireworks
        full.capacity = 0
        #expect(!byLabel.claimable(by: full, at: now), "no room for a start")
        let archive = QueueEntry(id: "4", kind: .archive, session: "s4", agent: .claude, title: "", runner: "mini", createdBy: "c", created: now)
        #expect(archive.claimable(by: full, at: now), "an archive needs no room")
        var claimed = byLabel
        claimed.state = .claimed
        claimed.leaseExpires = now.addingTimeInterval(60)
        #expect(!claimed.claimable(by: shireworks, at: now), "its lease is running")
        #expect(claimed.claimable(by: shireworks, at: now.addingTimeInterval(61)), "the runner it lapsed on is gone: back in the queue")
        var cancelled = byLabel
        cancelled.state = .cancelled
        #expect(!cancelled.claimable(by: shireworks, at: now))
    }

    @Test func testAClaimAndAnUpdateReadBack() {
        let entry = QueueEntry(id: "e1", session: "abc", agent: .claude, title: "Issue 12", repository: "AttilaTheFun/visor",
                               createdBy: "client:logan", created: Date(timeIntervalSince1970: 1_800_000_000))
        let claim = RunnerClaim(entry: entry, lease: "lease-1", expires: Date(timeIntervalSince1970: 1_800_000_060), agentToken: "t")
        #expect((RunnerClaim(json: reread(claim.json))) == claim)
        let started = RunnerUpdate(entry: "e1", lease: "lease-1", state: .started, dataLocation: "Sessions/Claude/abc")
        #expect((RunnerUpdate(json: reread(started.json))) == started)
        let failed = RunnerUpdate(entry: "e1", lease: "lease-1", state: .failed, problem: "no room after all")
        #expect((RunnerUpdate(json: reread(failed.json))?.problem) == "no room after all")
        #expect((RunnerUpdate(json: .object(["type": .string("update"), "entry": .string("e1"), "lease": .string("l"),
                                                 "state": .string("pondering")]))) == nil)
    }

    @Test func testAReportReadsBack() {
        let blocked = AgentReport(session: "abc", kind: .blocked, summary: "The pull request touches .github/",
                                  pullRequest: "https://github.com/AttilaTheFun/visor/pull/350", reason: .codeReview,
                                  at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect((AgentReport(json: reread(blocked.json))) == blocked)
        #expect((blocked.json["reason"].string) == "code_review", "the MCP tool's word for it")
        let complete = AgentReport(session: "abc", kind: .complete, summary: "Fixed and merged", pullRequest: "https://github.com/x/y/pull/1",
                                   merged: true, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect((AgentReport(json: reread(complete.json))?.merged) == true)
        let progress = AgentReport(session: "abc", kind: .progress, summary: "Running the tests", step: "tests",
                                   at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect((AgentReport(json: reread(progress.json))) == progress)
        #expect((AgentReport(json: .object(["type": .string("report"), "session": .string("abc"), "kind": .string("shrug"),
                                                "at": .number(0)]))) == nil)
    }
}
}

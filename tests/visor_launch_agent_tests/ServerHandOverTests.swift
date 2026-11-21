// The hand-over from the server in Visor.app to the server agent, with
// launchd and the agent played by fakes: off changes nothing, on hands
// over once the agent answers, and, on, the app never serves itself nor
// removes the agent, however it answers (NCH's check of #491).

import Testing
@testable import VisorLaunchAgent

/// launchd and the agent, played: what each step answers, and what was
/// asked.
private actor FakeSteps: ServerHandOverSteps {
    var isInstalled: Bool
    var installAction: LaunchAgentJob.Action
    var removeAction: LaunchAgentJob.Action
    var pid: Int32?
    /// How many looks before it answers; nil: never.
    var answersAfter: Int?
    private(set) var asked: [String] = []
    private var looks = 0

    init(installed: Bool = false, install: LaunchAgentJob.Action = .start, remove: LaunchAgentJob.Action = .stop, pid: Int32? = 4242,
         answersAfter: Int? = 0) {
        isInstalled = installed
        installAction = install
        removeAction = remove
        self.pid = pid
        self.answersAfter = answersAfter
    }

    func installed() async -> Bool { isInstalled }

    func install() async -> LaunchAgentJob.Action {
        asked.append("install")
        return installAction
    }

    func remove() async -> LaunchAgentJob.Action {
        asked.append("remove")
        return removeAction
    }

    func agentPID() async -> Int32? { pid }

    func answers(_ pid: Int32) async -> Bool {
        looks += 1
        guard let answersAfter else { return false }
        return looks > answersAfter
    }

    func pause(_ duration: Duration) async {
        asked.append("pause")
    }
}

@Suite struct ServerHandOverTests {
    private func run(wanted: Bool, _ steps: FakeSteps) async -> ServerHandOver.Outcome {
        await ServerHandOver.run(wanted: wanted, steps: steps, watch: .seconds(10), poll: .seconds(2), log: { _ in })
    }

    @Test func offWithNothingThereDoesNothing() async {
        let steps = FakeSteps()
        #expect(await run(wanted: false, steps) == .inApp(nil))
        #expect(await steps.asked.isEmpty, "nothing installed, removed or asked")
    }

    @Test func offRemovesAnAgentLeftFromWhenItWasOn() async {
        let steps = FakeSteps(installed: true)
        #expect(await run(wanted: false, steps) == .inApp(nil))
        #expect(await steps.asked == ["remove"])
    }

    @Test func offInACopyThatCantRemoveItUsesTheAgentThatServes() async {
        let steps = FakeSteps(installed: true, remove: .refuse("a copy outside /Applications"))
        #expect(await run(wanted: false, steps) == .agent(4242), "never two servers on the same data")
        let silent = FakeSteps(installed: true, remove: .refuse("a copy outside /Applications"), answersAfter: nil)
        #expect(await run(wanted: false, silent) == .inApp(nil))
    }

    @Test func onHandsOverOnceTheAgentAnswers() async {
        let steps = FakeSteps(answersAfter: 2)
        #expect(await run(wanted: true, steps) == .agent(4242))
        #expect(await steps.asked == ["install", "pause", "pause"], "installed, then waited for, never removed")
    }

    @Test func onWithTheSameAgentRunningUsesItAtOnce() async {
        let steps = FakeSteps(installed: true, install: .leave)
        #expect(await run(wanted: true, steps) == .agent(4242))
        #expect(await steps.asked == ["install"])
    }

    @Test func anAgentThatNeverAnswersIsWaitedForNeverRemovedAndTheAppServesNothing() async {
        let steps = FakeSteps(answersAfter: nil)
        guard case .waiting(let why) = await run(wanted: true, steps) else {
            Issue.record("the app waits for the agent")
            return
        }
        #expect(why.contains("hasn't answered within 10 seconds"))
        #expect(await steps.asked == ["install"] + Array(repeating: "pause", count: 5), "the watch, and nothing removed")
        let noProcess = FakeSteps(pid: nil)
        if case .waiting = await run(wanted: true, noProcess) {} else { Issue.record("no process: still waited for") }
        #expect(await !noProcess.asked.contains("remove"))
    }

    /// NCH's (a): the first launch after 0.64's plist. The old job gives way
    /// (install's restart), the new agent takes a while, or its
    /// registration waits for approval: the app waits as its client, never
    /// serving itself (which had the agent give way to it every 35 s).
    @Test func theFirstLaunchAfterZeroSixtyFoursPlistWaitsForTheNewAgent() async {
        let migrating = FakeSteps(installed: true, install: .restart("0.64's plist in ~/Library/LaunchAgents gives way to the app's own"),
                                  answersAfter: 3)
        #expect(await run(wanted: true, migrating) == .agent(4242))
        #expect(await migrating.asked == ["install", "pause", "pause", "pause"])
        let approval = FakeSteps(installed: true, install: .hold("it waits to be allowed in System Settings › General › Login Items"),
                                 answersAfter: nil)
        guard case .waiting(let why) = await run(wanted: true, approval) else {
            Issue.record("waited for, never the app's own server")
            return
        }
        #expect(why.contains("Login Items"))
        #expect(await !approval.asked.contains("remove"))
    }

    /// NCH's (b): a reopen (or `Visor --help`, which opened the window)
    /// with the agent registered and running: left as it is, never sent
    /// TERM, and the app its client.
    @Test func aReopenLeavesTheRunningAgentAlone() async {
        let reopened = FakeSteps(installed: true, install: .leave, answersAfter: 0)
        #expect(await run(wanted: true, reopened) == .agent(4242))
        #expect(await reopened.asked == ["install"])
        // Slow to answer just then: still never removed.
        let slow = FakeSteps(installed: true, install: .leave, answersAfter: nil)
        if case .waiting = await run(wanted: true, slow) {} else { Issue.record("waited for") }
        #expect(await !slow.asked.contains("remove"))
        // Whatever SMAppService says of it, a running agent is left.
        let app = "/Applications/Visor.app/Contents/MacOS/Visor"
        for status in [ServerAgentJob.ServiceStatus.enabled, .notRegistered, .notFound, .requiresApproval] {
            #expect(ServerAgentJob.decide(wanted: true, executable: app, status: status, legacyPlist: false, running: true) == .leave,
                    "\(status)")
        }
    }

    @Test func aCopyThatCantRegisterWaitsForTheRegisteredAgentOrServesWhenThereIsNone() async {
        let refused = FakeSteps(install: .refuse("a copy outside /Applications"), answersAfter: nil)
        #expect(await run(wanted: true, refused) == .inApp("the server agent can't be registered: a copy outside /Applications"))
        #expect(await refused.asked == ["install"], "nothing registered, nothing to remove")
        let registered = FakeSteps(installed: true, install: .refuse("a copy outside /Applications"), answersAfter: nil)
        if case .waiting = await run(wanted: true, registered) {} else { Issue.record("the registered agent is waited for") }
        #expect(await !registered.asked.contains("remove"))
        let serving = FakeSteps(installed: true, install: .refuse("a copy outside /Applications"))
        #expect(await run(wanted: true, serving) == .agent(4242))
    }

    /// Registering afresh is a bootout first, then the registration
    /// (SMAppService's launch constraint is the bundle it was registered
    /// from: after an update or a rollback, registering alone leaves
    /// launchd unable to spawn it).
    @Test func reregisteringBootsOutFirstThenRegisters() async {
        let calls = Calls()
        let problem = await ServerAgentJob.reregister(stop: { await calls.add("bootout") },
                                                      register: { await calls.add("register"); return nil })
        #expect(problem == nil)
        #expect(await calls.all == ["bootout", "register"])
        let refused = await ServerAgentJob.reregister(stop: {}, register: { "Operation not permitted" })
        #expect(refused == "Operation not permitted")
    }
}

private actor Calls {
    private(set) var all: [String] = []
    func add(_ call: String) { all.append(call) }
}

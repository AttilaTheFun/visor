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

    /// Registering afresh is LaunchServices told of the bundle again, an
    /// unregister and a bootout, then the registration; and, while launchd
    /// has no process of it a moment later, all of it again (on macOS
    /// 27.0.1 the first registration after the bundle changed was refused
    /// for its launch constraint, the next one ran the new build).
    @Test func reregisteringRefreshesUnregistersAndBootsOutThenRegistersUntilItRuns() async {
        let calls = Calls()
        let runs = Calls()
        let problem = await ServerAgentJob.reregister(refresh: { await calls.add("lsregister") }, unregister: { await calls.add("unregister") },
                                                      stop: { await calls.add("bootout") },
                                                      register: { await calls.add("register"); return nil },
                                                      running: { await runs.add("look"); return await runs.all.count > 1 },
                                                      pause: { await calls.add("pause \($0.components.seconds)") })
        #expect(problem == nil)
        let once = ["lsregister", "unregister", "bootout", "register", "pause 8"]
        #expect(await calls.all == once + once, "refused once (the constraint), then running")
        let refused = await ServerAgentJob.reregister(refresh: {}, unregister: {}, stop: {}, register: { "Invalid argument" },
                                                      running: { true }, pause: { _ in })
        #expect(refused == "Invalid argument", "a refusal for good isn't waited on")
        let never = Calls()
        let down = await ServerAgentJob.reregister(attempts: 3, refresh: {}, unregister: {}, stop: {},
                                                   register: { await never.add("register"); return nil }, running: { false }, pause: { _ in })
        #expect(down?.contains("after 3 registrations") == true)
        #expect(await never.all.count == 3)
    }

    /// NCH's check of #491: just after 0.64's plist was removed, macOS
    /// refused the registration ("Operation not permitted") until Background
    /// Items dropped 0.64's item. Refused twice, then allowed: waited out,
    /// the person told why, and running.
    @Test func aRegistrationMacOSRefusesForNowIsWaitedOut() async {
        let tries = Calls()
        let said = Calls()
        let problem = await ServerAgentJob.reregister(
            refresh: {}, unregister: {}, stop: {},
            register: {
                await tries.add("register")
                return await tries.all.count <= 2 ? "The operation couldn’t be completed. Operation not permitted" : nil
            },
            running: { true }, pause: { await said.add("pause \($0.components.seconds)") },
            waiting: { text in Task { await said.add(text) } })
        #expect(problem == nil)
        #expect(await tries.all.count == 3)
        let pauses = await said.all.filter { $0.hasPrefix("pause") }
        #expect(pauses == ["pause 2", "pause 4", "pause 8"], "backed off, then the usual look")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await said.all.contains { $0 == ServerAgentJob.waitingForLoginItems })
        #expect(await !said.all.contains { $0.localizedCaseInsensitiveContains("not permitted") })
    }

    /// Just after 0.64's plist is removed, Background Items keeps its item
    /// for a while (62 s in NCH's check of 0.68.1): the registration is
    /// waited for about five minutes then, the usual minute and a half
    /// first, and given up after that, saying how long.
    @Test func aRegistrationJustAfter064sPlistIsWaitedForLonger() async {
        let after = ServerAgentJob.refusedBackoff(afterLegacy: true)
        #expect(ServerAgentJob.refusedBackoff(afterLegacy: false) == ServerAgentJob.refusedBackoff)
        #expect(Array(after.prefix(ServerAgentJob.refusedBackoff.count)) == ServerAgentJob.refusedBackoff)
        let total = after.reduce(0) { $0 + $1.components.seconds }
        #expect(total >= 280 && total <= 320, "about five minutes: \(total) s")
        // Allowed at 62 s, as in NCH's check: the usual wait had room, the
        // longer one has more.
        let tries = Calls()
        let elapsed = Calls()
        let problem = await ServerAgentJob.reregister(refusedBackoff: after, refresh: {}, unregister: {}, stop: {},
                                                      register: {
                                                          await tries.add("register")
                                                          let waited = await elapsed.all.count
                                                          return waited < 9 ? "Operation not permitted" : nil
                                                      },
                                                      running: { true }, pause: { _ in await elapsed.add("pause") })
        #expect(problem == nil)
        // Never allowed: given up only after the whole five minutes.
        let never = await ServerAgentJob.reregister(refusedBackoff: after, refresh: {}, unregister: {}, stop: {},
                                                    register: { "Job is not allowed to bootstrap" },
                                                    running: { true }, pause: { _ in })
        #expect(never?.contains("about \(total) seconds") == true, "\(never ?? "")")
    }

    /// Refused for good: given up after about a minute and a half, saying
    /// so, never silently.
    @Test func aRegistrationMacOSNeverAllowsEndsInAClearNotice() async {
        let tries = Calls()
        let problem = await ServerAgentJob.reregister(refresh: {}, unregister: {}, stop: {},
                                                      register: { await tries.add("register"); return "Job is not allowed to bootstrap" },
                                                      running: { true }, pause: { _ in })
        #expect(await tries.all.count == ServerAgentJob.refusedBackoff.count + 1)
        #expect(problem?.contains("macOS didn't let Visor's server start for about 89 seconds") == true, "\(problem ?? "")")
        #expect(problem?.contains("Login Items") == true)
        #expect(ServerAgentJob.isRefusedForNow("Operation not permitted"))
        #expect(!ServerAgentJob.isRefusedForNow("Invalid argument"))
        // The hand-over then waits, the app serving nothing, and says why.
        let steps = FakeSteps(install: .hold(problem ?? ""), answersAfter: nil)
        guard case .waiting(let why) = await ServerHandOver.run(wanted: true, steps: steps, watch: .seconds(4), poll: .seconds(2),
                                                                log: { _ in }) else {
            Issue.record("waited for, never the app's own server")
            return
        }
        #expect(why.contains("macOS didn't let Visor's server start"))
    }
}

private actor Calls {
    private(set) var all: [String] = []
    func add(_ call: String) { all.append(call) }
}

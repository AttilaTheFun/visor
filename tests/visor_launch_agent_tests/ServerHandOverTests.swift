// The hand-over from the server in Visor.app to the server agent, with
// launchd and the agent played by fakes: off changes nothing, on hands
// over once the agent answers, and an agent that doesn't answer is removed
// and the server runs in the app after all.

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
    private func run(wanted: Bool, hasPassword: Bool = true, _ steps: FakeSteps) async -> ServerHandOver.Outcome {
        await ServerHandOver.run(wanted: wanted, hasPassword: hasPassword, steps: steps, watch: .seconds(10), poll: .seconds(2), log: { _ in })
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

    @Test func anAgentThatNeverAnswersIsRemovedAndTheAppServes() async {
        let steps = FakeSteps(answersAfter: nil)
        guard case .inApp(let why?) = await run(wanted: true, steps) else {
            Issue.record("the server runs in the app after all")
            return
        }
        #expect(why.contains("didn't answer within 10 seconds"))
        #expect(await steps.asked == ["install"] + Array(repeating: "pause", count: 5) + ["remove"], "the watch, then the agent removed")
        let noProcess = FakeSteps(pid: nil)
        if case .inApp = await run(wanted: true, noProcess) {} else { Issue.record("no process: not handed over") }
        #expect(await noProcess.asked.last == "remove")
    }

    @Test func anAgentThatCantBeInstalledOrStartedLeavesTheServerInTheApp() async {
        let refused = FakeSteps(install: .refuse("a copy outside /Applications"), answersAfter: nil)
        #expect(await run(wanted: true, refused) == .inApp("the server agent can't be installed: a copy outside /Applications"))
        #expect(await refused.asked == ["install"], "nothing written, nothing to remove")
        let held = FakeSteps(install: .hold("launchctl bootstrap: 5"), answersAfter: nil)
        guard case .inApp(let why?) = await run(wanted: true, held) else {
            Issue.record("the server runs in the app")
            return
        }
        #expect(why.contains("couldn't be started"))
        #expect(await held.asked == ["install", "remove"])
    }

    @Test func noPasswordYetKeepsTheServerInTheApp() async {
        let steps = FakeSteps(installed: true)
        #expect(await run(wanted: true, hasPassword: false, steps)
                == .inApp("no password is set yet: the server runs in the app until it has one"))
        #expect(await steps.asked == ["remove"])
    }
}

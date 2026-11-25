// The hand-back from the server agent to the app (0.72.1), with launchd and
// the server played by fakes: with nothing there, the server starts in the
// app and nothing is touched; with the agent registered or running, an
// update's watch is waited out, the agent unregistered and stopped (it
// steps aside: its agents' hosts left running), its socket and port waited
// for, and only then the server starts in the app; `/api/quit` is the last
// resort, and a server that still answers is never served over.

import Testing
@testable import VisorLaunchAgent

/// launchd and the server agent, played: what each step answers, and what
/// was asked, in order.
private actor FakeSteps: ServerHandBackSteps {
    var there: Bool
    var removeAction: LaunchAgentJob.Action
    /// How many looks a server still answers for; nil: always.
    var answersFor: Int?
    /// Looks at the server once it's removed: it answers until it's
    /// stopped, then for `answersFor` more.
    var stopped = false
    /// How many looks an update's watch still holds its lock for.
    var watchFor: Int
    /// Whether `/api/quit` makes it go.
    var quitStops: Bool
    private(set) var asked: [String] = []
    private var looks = 0
    private var watchLooks = 0

    init(there: Bool, answering: Bool = true, remove: LaunchAgentJob.Action = .stop, answersFor: Int? = 2, watchFor: Int = 0,
         quitStops: Bool = true) {
        self.there = there
        removeAction = remove
        self.answersFor = answering ? answersFor : 0
        self.watchFor = watchFor
        self.quitStops = quitStops
        stopped = !answering
    }

    func agentThere() async -> Bool { there }

    func watching() async -> Int? {
        watchLooks += 1
        guard watchLooks <= watchFor else { return nil }
        asked.append("watching")
        return 120
    }

    func remove() async -> LaunchAgentJob.Action {
        asked.append("remove")
        if case .stop = removeAction { stopped = true }
        return removeAction
    }

    func serverAnswers() async -> Bool {
        guard stopped else { return true }
        guard let answersFor else { return true }
        looks += 1
        return looks <= answersFor
    }

    func quit() async -> String? {
        asked.append("quit")
        if quitStops { answersFor = looks }
        return nil
    }

    func pause(_ duration: Duration) async {}
}

@Suite struct ServerHandBackTests {
    private func run(_ steps: FakeSteps) async -> ServerHandBack.Outcome {
        await ServerHandBack.run(steps: steps, freeWithin: .seconds(5), watchLongest: .seconds(10), poll: .seconds(1), log: { _ in })
    }

    @Test func nothingThereStartsTheServerInTheAppTouchingNothing() async {
        let steps = FakeSteps(there: false, answering: false)
        #expect(await run(steps) == .inApp(nil))
        #expect(await steps.asked.isEmpty, "no launchd, no quit")
    }

    @Test func aRegisteredAgentIsUnregisteredAndStoppedThenTheServerStartsInTheApp() async {
        let steps = FakeSteps(there: true, answersFor: 2)
        #expect(await run(steps) == .inApp("the server agent was handed back"))
        #expect(await steps.asked == ["remove"], "stopped by launchd's TERM, its hosts left running: never /api/quit first")
    }

    @Test func aRegisteredAgentThatIsntRunningIsUnregisteredAndTheServerStarts() async {
        let steps = FakeSteps(there: true, answering: false)
        #expect(await run(steps) == .inApp("the server agent was handed back"))
        #expect(await steps.asked == ["remove"])
    }

    @Test func anUpdatesWatchIsWaitedForFirst() async {
        let steps = FakeSteps(there: true, watchFor: 3)
        #expect(await run(steps) == .inApp("the server agent was handed back"))
        #expect(await steps.asked == ["watching", "watching", "watching", "remove"], "the agent is never stopped mid-watch")
    }

    @Test func aWatchThatOutlastsItsLongestIsntWaitedForForever() async {
        let steps = FakeSteps(there: true, watchFor: 1_000)
        _ = await run(steps)
        let asked = await steps.asked
        #expect(asked.filter { $0 == "watching" }.count == 11)
        #expect(asked.last == "remove")
    }

    @Test func aServerThatStaysIsAskedToQuitLast() async {
        let steps = FakeSteps(there: true, answersFor: nil)
        #expect(await run(steps) == .inApp("the server agent was asked to quit"))
        #expect(await steps.asked == ["remove", "quit"])
    }

    @Test func aServerThatStillAnswersIsNeverServedOver() async {
        let steps = FakeSteps(there: true, answersFor: nil, quitStops: false)
        guard case .elsewhere = await run(steps) else {
            Issue.record("the app served beside another server")
            return
        }
        #expect(await steps.asked == ["remove", "quit"])
    }

    @Test func aCopyThatMayNotRemoveTheAgentIsItsClient() async {
        let steps = FakeSteps(there: true, remove: .refuse("not in /Applications"), answersFor: nil)
        #expect(await run(steps) == .elsewhere("the server agent is left serving: not in /Applications"))
        #expect(await steps.asked == ["remove"], "nothing asked to quit")
    }

    @Test func noAgentButAServerAnsweringIsWaitedForThenAskedToQuit() async {
        let steps = FakeSteps(there: false, answersFor: nil)
        // Stopped by nobody: still answering, then asked to quit.
        #expect(await run(steps) == .elsewhere("a server still answers at the socket file or on the port after the hand-back"))
        #expect(await steps.asked == ["quit"])
    }
}

// The server handed back from the server agent (`Visor --server`,
// ServerAgentJob) to the app, at the app's launch, before it makes a
// server of its own (0.72.1: the server runs in the app, docs/DEVELOPMENT.md,
// The server in the app). It runs unattended, on the first launch of the
// new version after an update that the agent itself installed:
//
// 1. Nothing there (no agent registered, no 0.64 plist, launchd running
//    none) and nothing answering at the socket file or on the port: the
//    server starts in the app, nothing else done.
// 2. An update's watch still holding its lock (RelaunchWatchLock, its
//    holder checked to be that watcher, RelaunchWatchHolder: the
//    agent's own watcher, from the build before, watching the new build
//    as the agent): waited for, since an agent gone mid-watch would be
//    taken for a crash and the update undone.
// 3. The agent unregistered (SMAppService) and booted out of launchd, and
//    0.64's plist removed (ServerAgentService.settle, not wanted): launchd's
//    TERM, on which the agent steps aside as an in-place relaunch does,
//    leaving the agents' hosts running for the app's server to pick up.
//    Not `/api/quit` first: that ends the agents (VisorServer.endAll).
// 4. Its socket file and port waited for to be free; if a server still
//    answers there, it's asked to quit (`/api/quit`, as the app's client),
//    the last resort, and waited for again.
// 5. The server starts in the app.
//
// A copy of the app that may not remove the agent (one outside
// /Applications) leaves it serving and is its client, as is an app that
// finds a server still answering after all that: never two servers on one
// Mac's data. Every step is logged.

import VisorServer

public enum ServerHandBack {
    /// What the app does with its server.
    public enum Outcome: Equatable, Sendable {
        /// The server runs in the app; what was done, when there was an
        /// agent to hand back.
        case inApp(String?)
        /// Another server answers and stays (why): the app is its client,
        /// and runs none of its own.
        case elsewhere(String)
    }

    /// How long the agent has to be gone after it's stopped, and again
    /// after `/api/quit`.
    public static let freeWithin: Duration = .seconds(40)
    /// The longest an update's watch is waited for: the lock's own longest,
    /// and a little more.
    public static let watchLongest: Duration = .seconds(RelaunchWatchLock.longest + 40)
    /// How often it's looked at meanwhile.
    public static let poll: Duration = .seconds(1)

    public static func run(steps: some ServerHandBackSteps, freeWithin: Duration = freeWithin, watchLongest: Duration = watchLongest,
                           poll: Duration = poll, log: @Sendable (String) -> Void) async -> Outcome {
        let there = await steps.agentThere()
        if !there, !(await steps.serverAnswers()) { return .inApp(nil) }
        if there {
            var waited: Duration = .zero
            while let left = await steps.watching(), waited < watchLongest {
                if waited == .zero { log("hand-back: an update's watch is still running (up to \(left) s left): waited for first") }
                await steps.pause(poll)
                waited += poll
            }
            log("hand-back: unregistering and stopping the server agent")
            let action = await steps.remove()
            switch action {
            case .refuse(let why), .hold(let why):
                let kind = action == .refuse(why) ? "refused" : "held"
                log("hand-back: the server agent wasn't removed: \(kind) (\(why))")
                if await steps.serverAnswers() {
                    log("hand-back: the server agent is left serving: this app is its client")
                    return .elsewhere("the server agent is left serving: \(why)")
                }
                log("hand-back: nothing answers: the server starts in the app")
                return .inApp("the server agent wasn't removed (\(why)), and nothing answered")
            default:
                log("hand-back: the server agent is unregistered and stopped (it steps aside, the agents' hosts left running)")
            }
        } else {
            log("hand-back: no server agent, but a server answers at the socket file or on the port: waited for to go")
        }
        if await gone(steps, within: freeWithin, poll: poll) {
            log("hand-back: the socket file and the port are free: the server starts in the app")
            return .inApp("the server agent was handed back")
        }
        log("hand-back: a server still answers after \(freeWithin.components.seconds) s: asked to quit (/api/quit)")
        if let problem = await steps.quit() { log("hand-back: /api/quit: \(problem)") }
        if await gone(steps, within: freeWithin, poll: poll) {
            log("hand-back: the socket file and the port are free: the server starts in the app")
            return .inApp("the server agent was asked to quit")
        }
        let why = "a server still answers at the socket file or on the port after the hand-back"
        log("hand-back: \(why): this app is its client, and runs no server of its own")
        return .elsewhere(why)
    }

    /// Whether nothing answers any more, within `within`.
    private static func gone(_ steps: some ServerHandBackSteps, within: Duration, poll: Duration) async -> Bool {
        var waited: Duration = .zero
        while await steps.serverAnswers() {
            guard waited < within else { return false }
            await steps.pause(poll)
            waited += poll
        }
        return true
    }
}

/// What the hand-back does to launchd and asks of the server: the Mac's
/// (LaunchdHandBackSteps), or a test's fakes.
public protocol ServerHandBackSteps: Sendable {
    /// Whether the server agent is there: registered (or waiting for
    /// approval), 0.64's plist, or launchd runs it.
    func agentThere() async -> Bool
    /// Seconds an update's watch holding its lock has left; nil when none
    /// does (a lock whose pid now names another process holds nothing:
    /// RelaunchWatchHolder).
    func watching() async -> Int?
    /// The agent unregistered and stopped (TERM: it steps aside), and
    /// 0.64's plist removed: what was done.
    func remove() async -> LaunchAgentJob.Action
    /// Whether a server answers at the socket file or on the port.
    func serverAnswers() async -> Bool
    /// `/api/quit`, as the app's client: what went wrong, or nil.
    func quit() async -> String?
    /// Waits, between two looks.
    func pause(_ duration: Duration) async
}

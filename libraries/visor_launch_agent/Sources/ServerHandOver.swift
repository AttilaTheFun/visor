// The hand-over from the server in Visor.app to the server agent
// (ServerAgentJob), decided at the app's launch, before the app makes a
// server of its own:
//
// - Wanted (the `ServerAsAgent` default on): the agent is registered and
//   started (left, if one is running: never stopped), and the app waits up
//   to the watch (two minutes, AppRelauncher's) for it to answer
//   `/api/hello` on the server's port from the job's own process. Then the
//   app is its client. If it doesn't answer yet (it waits for approval in
//   Login Items, or launchd is slow), the app still never serves itself and
//   never removes it (NCH's check of #491: an app that did took the server
//   back from the agent it had just registered, which then gave way to it
//   every 35 seconds): it stays the agent's client, and says why it waits.
//   With no password yet the agent serves the app at its socket file, where
//   the app sets one.
// - Not wanted: an agent left from when it was is removed (it leaves its
//   agents' hosts running, as an in-place relaunch does, for the app's
//   server to pick up), and the server runs in the app. Nothing there:
//   nothing is done at all.
// - A copy of the app that may not register or remove the agent (one
//   outside /Applications) uses an agent that serves, or waits for one
//   that's registered; with none, it runs its own server.
//
// The server that was in the app has gone by then as an in-place relaunch
// goes (VisorServer.relaunch: the hosts left running), which is how the
// setting takes effect: turned on, then Visor restarted.

public enum ServerHandOver {
    /// What the app does with its server.
    public enum Outcome: Equatable, Sendable {
        /// The server runs in the app, as before; why, when an agent was
        /// wanted and isn't used.
        case inApp(String?)
        /// The agent serves, as process `pid`: the app is its client.
        case agent(Int32)
        /// The agent is wanted and doesn't answer yet (why): the app is its
        /// client still, and serves nothing itself.
        case waiting(String)
    }

    /// How long the agent has to answer: AppRelauncher's watch.
    public static let watch: Duration = .seconds(120)
    /// How often it's looked at meanwhile.
    public static let poll: Duration = .seconds(2)

    public static func run(wanted: Bool, steps: some ServerHandOverSteps, watch: Duration = watch, poll: Duration = poll,
                           log: @Sendable (String) -> Void) async -> Outcome {
        guard wanted else {
            guard await steps.installed() else { return .inApp(nil) }
            switch await steps.remove() {
            case .refuse(let reason), .hold(let reason):
                // Left as it is: if it serves, it's this Mac's server.
                if let pid = await answering(steps) {
                    log("the server agent (process \(pid)) is left serving (\(reason)): this app is its client")
                    return .agent(pid)
                }
            default:
                break
            }
            return .inApp(nil)
        }
        var why: String?
        switch await steps.install() {
        case .refuse(let reason):
            // Nothing registered by this copy: one registered by another
            // is waited for, never replaced; with none, the app serves.
            if let pid = await answering(steps) { return .agent(pid) }
            guard await steps.installed() else { return .inApp("the server agent can't be registered: \(reason)") }
            why = reason
        case .hold(let reason):
            why = reason
        default:
            break
        }
        var waited: Duration = .zero
        while true {
            if let pid = await answering(steps) {
                log("the server agent (process \(pid)) answers: this app is its client")
                return .agent(pid)
            }
            guard waited < watch else { break }
            await steps.pause(poll)
            waited += poll
        }
        let said = "the server agent hasn't answered within \(watch.components.seconds) seconds"
            + (why.map { " (\($0))" } ?? "") + ": this app waits for it as its client, and runs no server of its own while it's wanted"
        log(said)
        return .waiting(said)
    }

    /// The agent's process, when it answers.
    private static func answering(_ steps: some ServerHandOverSteps) async -> Int32? {
        guard let pid = await steps.agentPID(), await steps.answers(pid) else { return nil }
        return pid
    }
}

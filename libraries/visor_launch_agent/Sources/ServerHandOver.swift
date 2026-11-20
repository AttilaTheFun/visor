// The hand-over from the server in Visor.app to the server agent
// (ServerAgentJob), decided at the app's launch, before the app makes a
// server of its own:
//
// - Wanted (the `ServerAsAgent` default on, and a password set): the agent
//   is installed and started (left, if the same is running), and the app
//   waits up to the watch (two minutes, AppRelauncher's) for it to answer
//   `/api/hello` on the server's port from the job's own process. Then the
//   app is its client. If it doesn't, the agent is removed and the server
//   runs in the app, as before.
// - Not wanted: an agent left from when it was is removed (it leaves its
//   agents' hosts running, as an in-place relaunch does, for the app's
//   server to pick up), and the server runs in the app. Nothing there:
//   nothing is done at all.
// - A copy of the app that may not write or remove the job (one outside
//   /Applications) uses an agent that serves, else runs its own server.
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
    }

    /// How long the agent has to answer: AppRelauncher's watch.
    public static let watch: Duration = .seconds(120)
    /// How often it's looked at meanwhile.
    public static let poll: Duration = .seconds(2)

    public static func run(wanted: Bool, hasPassword: Bool, steps: some ServerHandOverSteps, watch: Duration = watch, poll: Duration = poll,
                           log: @Sendable (String) -> Void) async -> Outcome {
        guard wanted, hasPassword else {
            let why = wanted ? "no password is set yet: the server runs in the app until it has one" : nil
            guard await steps.installed() else { return .inApp(why) }
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
            return .inApp(why)
        }
        let action = await steps.install()
        switch action {
        case .refuse(let why):
            // Nothing written: an agent from another copy may still serve.
            if let pid = await answering(steps) { return .agent(pid) }
            return .inApp("the server agent can't be installed: \(why)")
        case .hold(let why):
            if let pid = await answering(steps) { return .agent(pid) }
            _ = await steps.remove()
            return .inApp("the server agent couldn't be started (\(why)): it was removed, and the server runs in the app")
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
        _ = await steps.remove()
        return .inApp("the server agent didn't answer within \(watch.components.seconds) seconds: it was removed, and the server runs in the app")
    }

    /// The agent's process, when it answers.
    private static func answering(_ steps: some ServerHandOverSteps) async -> Int32? {
        guard let pid = await steps.agentPID(), await steps.answers(pid) else { return nil }
        return pid
    }
}

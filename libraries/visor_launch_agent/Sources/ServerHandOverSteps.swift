// What the hand-over (ServerHandOver) does to launchd and asks of the
// server: the Mac's (LaunchdHandOverSteps), or a test's fakes.

public protocol ServerHandOverSteps: Sendable {
    /// Whether the server's job is there: its plist, or launchd has it
    /// running.
    func installed() async -> Bool
    /// The job written and started (or left running, the same), as the app
    /// that asks is: what was done.
    func install() async -> LaunchAgentJob.Action
    /// The job stopped (it leaves its agents' hosts running, as an in-place
    /// relaunch does) and its plist removed: what was done.
    func remove() async -> LaunchAgentJob.Action
    /// The job's process id while it runs.
    func agentPID() async -> Int32?
    /// Whether process `pid` answers `/api/hello` on the server's port.
    func answers(_ pid: Int32) async -> Bool
    /// Waits, between two looks.
    func pause(_ duration: Duration) async
}

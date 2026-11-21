/// How long the MCP server waits between the things it does on its own:
/// a test's are short.
package struct MCPTiming: Sendable {
    /// How often an `approve` the person is deciding says it is still
    /// waiting, where the agent takes progress.
    var heartbeat: Duration = .seconds(20)
    /// How long an `approve` with no progress waits before it is answered
    /// "not yet": under the 30 minutes Claude Code gives a quiet call.
    var unanswered: Duration = .seconds(25 * 60)
    /// How often the MCP servers the computer passes on are looked at again.
    var watch: Duration = .seconds(30)
    /// How long one look at the passed-on tools may take before it is given
    /// up on (the last good list kept): the server answers from each
    /// endpoint's last good list within its own limits (MCPProxy's
    /// `listTimeout`, for `initialize` and for the list), so only a server
    /// that has stopped answering takes this long.
    var look: Duration = .seconds(15)
    /// The wait after a look that failed (the server restarting, say),
    /// doubled after each that fails again, up to `watch`.
    var retry: Duration = .seconds(2)

    package init(heartbeat: Duration = .seconds(20), unanswered: Duration = .seconds(25 * 60), watch: Duration = .seconds(30),
                 look: Duration = .seconds(15), retry: Duration = .seconds(2)) {
        self.heartbeat = heartbeat
        self.unanswered = unanswered
        self.watch = watch
        self.look = look
        self.retry = retry
    }
}

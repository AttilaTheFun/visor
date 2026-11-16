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

    package init(heartbeat: Duration = .seconds(20), unanswered: Duration = .seconds(25 * 60), watch: Duration = .seconds(30)) {
        self.heartbeat = heartbeat
        self.unanswered = unanswered
        self.watch = watch
    }
}

/// How the process that runs the server is replaced and ended: an app is
/// reopened by the system, a command-line server starts its successor.
public protocol ServerLifecycle: Sendable {
    /// Starts whatever brings the server back once this process has gone,
    /// with `build` (a path) installed over this one first when given, and
    /// told to carry on `sessions` (comma-separated ids, or empty for
    /// everything that was running). Returns what went wrong, or nil.
    @MainActor
    func relaunch(installing build: String?, carrying sessions: String) -> String?
    /// Ends this process; its agents have already been ended.
    @MainActor
    func terminate()
}

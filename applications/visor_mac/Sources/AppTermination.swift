// How Visor.app ends while its server runs in its own process: the server
// is asked to stop as any client asks it (`/api/quit`, LocalServer), it
// ends its agents (or, relaunching, leaves them under their hosts), and
// then ends the app through its lifecycle (AppLifecycle). A quit that
// comes from outside (logging out, another app asking) waits for that
// (AppDelegate.applicationShouldTerminate); the server agent's agents are
// its own, and the app quits alone.

@MainActor
enum AppTermination {
    /// The server has ended its agents and asked to end the app.
    static var serverEnded = false
    /// A quit is waiting on the server (`.terminateLater`).
    static var pending = false
}

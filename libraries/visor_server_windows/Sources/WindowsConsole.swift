import Synchronization
import WinSDK

/// The console's word that the process is asked to stop: Ctrl-C,
/// Ctrl-Break, its window closing, the user logging off, the system
/// shutting down.
enum WindowsConsole {
    private static let stopping = Mutex<(@Sendable () -> Void)?>(nil)

    /// Calls `stop` once, at the first of them.
    static func onStop(_ stop: @escaping @Sendable () -> Void) {
        stopping.withLock { $0 = stop }
        _ = SetConsoleCtrlHandler({ event in
            let stop = WindowsConsole.stopping.withLock { handler in
                defer { handler = nil }
                return handler
            }
            stop?()
            // A window closing, a log-off or a shutdown ends the process as
            // soon as this returns: a few seconds for the agents to go.
            if event == 2 || event == 5 || event == 6 { Sleep(4500) }
            return true
        }, true)
    }
}

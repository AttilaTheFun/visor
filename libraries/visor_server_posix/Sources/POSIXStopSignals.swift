import Dispatch
import Foundation
import Synchronization

/// The signals that ask a process to stop — Ctrl-C (SIGINT), the system's
/// request (SIGTERM), its terminal closing (SIGHUP) — heard on the main
/// queue instead of ending the process at once.
@MainActor
public enum POSIXStopSignals {
    /// The sources, kept for as long as the process runs.
    private static var watching: [any DispatchSourceSignal] = []

    /// Calls `stop` once, at the first of them.
    public static func onStop(_ stop: @escaping @Sendable () -> Void) {
        let once = Once()
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { if once.first() { stop() } }
            source.resume()
            watching.append(source)
        }
    }
}

/// True the first time it is asked, false after.
private final class Once: Sendable {
    private let done = Mutex(false)

    func first() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}

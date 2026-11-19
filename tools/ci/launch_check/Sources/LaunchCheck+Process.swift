import AppKit
import Foundation

/// The app's process and its server, as the check sees them from outside.
extension LaunchCheck {
    /// The newest process named as the app's executable, if one runs.
    static func processID(of app: VisorApp) throws -> pid_t? {
        let found = try Program.run("/usr/bin/pgrep", ["-n", "-x", app.executable])
        return found.succeeded ? pid_t(found.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The HTTP status /api/hello answered with, or nil when nothing
    /// answered (curl's 000). Any status is an answer: a server that
    /// refuses an unknown caller is up.
    static func hello() throws -> Int? {
        let curl = try Program.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5",
                                                     "http://127.0.0.1:\(port)/api/hello"])
        guard let status = Int(curl.output.trimmingCharacters(in: .whitespacesAndNewlines)), status > 0 else { return nil }
        return status
    }

    /// Quits the app as a user would (a quit event), then by signal if it
    /// hasn't gone in 15 seconds.
    static func quit(_ pid: pid_t) {
        guard isRunning(pid) else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
        for signal in [SIGTERM, SIGKILL] {
            let deadline = Date().addingTimeInterval(signal == SIGTERM ? 15 : 5)
            while isRunning(pid), Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            guard isRunning(pid) else { return }
            kill(pid, signal)
        }
    }
}

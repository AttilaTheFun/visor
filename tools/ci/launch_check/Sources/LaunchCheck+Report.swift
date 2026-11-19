import Foundation

/// What the check prints when the app fails: why, in the app's own words.
extension LaunchCheck {
    /// The newest crash report the app left since `since` (macOS writes it
    /// a few seconds after the crash: waited for up to 30), then the app's
    /// unified-log lines since then, the last 200.
    static func report(_ app: VisorApp, since: Date) {
        var crash: URL?
        let deadline = Date().addingTimeInterval(30)
        while crash == nil, Date() < deadline {
            crash = CrashReport.newest(named: app.executable, since: since)
            if crash == nil { Thread.sleep(forTimeInterval: 1) }
        }
        if let crash {
            do {
                print(try CrashReport(contentsOf: crash).summary())
            } catch {
                print("Crash report: \(error)")
            }
        } else {
            print("Crash report: none from \(app.executable) in ~/Library/Logs/DiagnosticReports since it was opened")
        }

        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("\nThe app's log (subsystem \(subsystem)):")
        do {
            let log = try Program.run("/usr/bin/log", ["show", "--style", "compact", "--info", "--start", format.string(from: since),
                                                       "--predicate", "subsystem == \"\(subsystem)\""])
            let lines = log.output.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 200 { print("  (the last 200 of \(lines.count) lines)") }
            print(lines.suffix(200).joined(separator: "\n"))
            if !log.succeeded { print("  (log show exited \(log.status))") }
        } catch {
            print("  \(error)")
        }
    }

    /// Where a running app is stuck, when it runs but doesn't answer: its
    /// main thread, sampled (`sample`), the top of its call tree. One stuck
    /// in the keychain is waiting on a dialog: an item a differently signed
    /// Visor left (a check run before on the same Mac) asks before it is
    /// read.
    static func printHang(_ pid: pid_t) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("launch_check-sample-\(pid).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? Program.run("/usr/bin/sample", ["\(pid)", "2", "-file", file.path]))?.succeeded == true,
              let text = try? String(contentsOf: file, encoding: .utf8) else {
            print("Hang: \(pid) couldn't be sampled")
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains("com.apple.main-thread") }) else {
            print("Hang: no main thread in \(pid)'s sample")
            return
        }
        print("Hang: \(pid)'s main thread (sample):")
        print(lines[start...].prefix(30).joined(separator: "\n"))
        if text.contains("SecItemCopyMatching") || text.contains("SecKeychain") {
            print("  (in the keychain: an item a differently signed Visor left asks first; remove the app's items, `security delete-generic-password -s com.LoganShire.Visor.server`, and run again)")
        }
    }
}

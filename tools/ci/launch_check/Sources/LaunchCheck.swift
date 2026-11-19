import Foundation

/// Whether a Visor.app starts for real and stays up, the check a release's
/// signed Mac app passes before it is proposed or attached (ci.yml). Visor
/// 0.62.1, built by Xcode 27.2, passed every proof (fixture mode, no
/// server) and aborted at launch on macOS 27.0 in `swift_task_dealloc`;
/// this is what would have caught it.
///
///     bazel run //tools/ci/launch_check -- <Visor.app | Visor-<version>-macos.zip> [--startup <s>] [--hold <s>]
///
/// It puts a stand-in `claude` where the app looks (StandInClaude), gives
/// the app a fresh data folder whose server asks nothing (AppData: one with
/// no password never listens), opens the app as a user would (`open`: not
/// fixture mode, so its server starts), waits for `http://127.0.0.1:7433/api/hello` to answer (any
/// HTTP answer: the server is up), then checks for `--hold` seconds (60)
/// that the same process is running and the server still answering, and
/// quits the app. When it fails it prints the newest crash report the app
/// left (its exception, `asi` and the faulting thread's top frames) and the
/// app's own unified-log lines.
///
/// Exits 0 when the app passed, 1 when it didn't, 2 when the check
/// couldn't be made (the arguments; a Visor already running, 7433 already
/// answering, or a Visor data folder not the check's: it runs on a CI Mac
/// or a leased VM, never a Mac someone is using).
@main
@MainActor
enum LaunchCheck {
    static let port = 7433
    /// The subsystem the app's server logs under (ServerPlatform+Apple).
    static let subsystem = "com.LoganShire.Visor"

    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            exit(try check(options) ? 0 : 1)
        } catch {
            say("\(error)")
            exit(2)
        }
    }

    /// The check, start to end: true when the app passed. Throws when it
    /// couldn't be made.
    static func check(_ options: Options) throws -> Bool {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("launch_check-\(getpid())")
        try? files.removeItem(at: work)
        do {
            try files.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw LaunchCheckError.setup("no work folder at \(work.path): \(error.localizedDescription)")
        }
        defer { try? files.removeItem(at: work) }

        let app = try VisorApp.prepare(options.app, in: work)
        say("\(app.url.lastPathComponent) \(app.version) (\(app.bundleID)), from \(options.app)")
        if let running = try processID(of: app) {
            throw LaunchCheckError.setup("\(app.executable) is already running (pid \(running)): the check opens its own")
        }
        if let status = try hello() {
            throw LaunchCheckError.setup("something already answers on port \(port) (HTTP \(status)): the check needs it free")
        }
        let data = try AppData.prepare()
        defer { data.remove() }
        let claude = try StandInClaude.install(in: work)
        defer { claude.remove() }

        // A second early, so a report written the instant the app starts
        // is still this launch's.
        let launched = Date().addingTimeInterval(-1)
        let failure = run(app, path: "\(claude.folder.path):/usr/bin:/bin:/usr/sbin:/sbin", options: options)
        if let failure {
            say("FAILED: \(failure)")
            report(app, since: launched)
            return false
        }
        say("PASSED: \(app.url.lastPathComponent) \(app.version) started and stayed up \(options.hold) s")
        return true
    }

    /// Opens the app and watches it, then quits it: nil when it passed,
    /// else what went wrong.
    static func run(_ app: VisorApp, path: String, options: Options) -> String? {
        let opened: Program
        do {
            opened = try Program.run("/usr/bin/open", ["--env", "PATH=\(path)", app.url.path])
        } catch {
            return "\(error)"
        }
        guard opened.succeeded else { return "open couldn't open it (\(opened.status)): \(opened.output)" }
        let start = Date()
        var pid: pid_t?
        defer { if let pid { quit(pid) } }

        // Up: the process there and the server answering.
        while true {
            let waited = Int(Date().timeIntervalSince(start))
            if pid == nil { pid = try? processID(of: app) }
            if let pid, !isRunning(pid) {
                return "\(app.executable) (pid \(pid)) exited \(waited) s after it was opened, before its server answered"
            }
            if pid != nil, let status = try? hello() {
                say("its server answered /api/hello (HTTP \(status)) \(waited) s after it was opened, pid \(pid ?? 0)")
                break
            }
            if waited >= options.startup {
                guard let pid else { return "\(app.executable) never started (\(options.startup) s)" }
                printHang(pid)
                return "its server didn't answer /api/hello on port \(port) within \(options.startup) s (\(app.executable) still running, pid \(pid))"
            }
            Thread.sleep(forTimeInterval: 1)
        }
        guard let process = pid else { return "\(app.executable) never started" }

        // Held: the same process, answering, for the whole time. A few
        // missed answers in a row (a busy server) are not yet a failure.
        let answered = Date()
        var missed = 0
        while Date().timeIntervalSince(answered) < Double(options.hold) {
            Thread.sleep(forTimeInterval: 2)
            let held = Int(Date().timeIntervalSince(answered))
            guard isRunning(process) else { return "\(app.executable) (pid \(process)) exited \(held) s after its server answered" }
            if (try? hello()) != nil {
                missed = 0
            } else {
                missed += 1
                if missed >= 3 {
                    printHang(process)
                    return "its server stopped answering /api/hello \(held) s after it first did"
                }
            }
        }
        return nil
    }

    /// One line of the check's own, on standard error.
    static func say(_ line: String) {
        FileHandle.standardError.write(Data("launch_check: \(line)\n".utf8))
    }
}

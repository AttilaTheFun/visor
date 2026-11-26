// The update watchers' scripts, as Visor.app builds them, read by macOS's
// own /bin/sh (`-n`: read, never run), which is bash 3.2. NCH's lease test
// of 0.72.1: the app's watcher died at line 48 with "syntax error near
// unexpected token `;;'", bash 3.2 reading a case's `pattern)` inside
// `$( … )` as the substitution's end. Linux's tests run the same scripts
// with bash 5 or dash, which read them as meant, so only a Mac's shell
// catches this; CI's test job runs this bundle on one.

import Foundation
import VisorLaunchAgent
import VisorServer
import XCTest

final class RelaunchScriptSyntaxTests: XCTestCase {
    private let destination = "/Applications/Visor.app"
    private let support = "/Users/me/Library/Application Support/Visor"

    /// What the app's agent is, as AppLifecycle gives it.
    private var commands: AppRelaunchCommands {
        AppRelaunchCommands(executable: destination + "/Contents/MacOS/Visor",
                            open: AppRelaunchCommands.opening(destination, sessions: "all", withoutAgent: true),
                            agent: .init(label: "com.LoganShire.Visor.app", command: ["app-agent", "start"],
                                         instanceLock: "/var/folders/xy/abc/T/com.LoganShire.Visor.instance.lock"))
    }

    /// The app's watch as AppRelauncher builds it: an update or a plain
    /// restart, serving on the port or not, a window open or not.
    private func appWatch(update: Bool, serving: Bool, window: Bool, commands: AppRelaunchCommands) -> AppRelaunchWatch {
        let backup = support + "/Previous/abcd1234/Visor.app"
        return AppRelaunchWatch(appPID: 4242, destination: destination, backup: update ? backup : nil,
                                install: update ? AppRelaunchCommands.replacing(destination, with: "/Users/me/Downloads/Visor 0.72.2/Visor.app",
                                                                                keptAt: backup, sessions: "all") : "",
                                accept: AppRelaunchCommands.accept(destination), start: commands.start, stop: commands.stop, pid: commands.pid,
                                answers: serving ? AppRelaunchWatch.portAnswers() : AppRelaunchWatch.socketAnswers("/Volumes/Visor/run/server.sock"),
                                answersWhere: serving ? "on port 7433" : "at its socket file", note: support + "/relaunch-rollback.txt",
                                newVersion: "0.72.2", oldVersion: "0.72.1", lock: support + "/relaunch-watch.lock",
                                present: window ? "/var/folders/xy/abc/T/com.LoganShire.Visor.present" : nil)
    }

    func testTheAppsWatchReadsUnderMacOSsShell() throws {
        for update in [true, false] {
            for serving in [true, false] {
                for window in [true, false] {
                    let script = appWatch(update: update, serving: serving, window: window, commands: commands).script()
                    try assertReads(script, "the app's watch (update \(update), serving \(serving), window \(window))")
                }
            }
        }
    }

    /// An app with no agent (no lock): found by its path alone, the case
    /// statement and all.
    func testTheWatchOfAnAppWithNoAgentReadsUnderMacOSsShell() throws {
        let alone = AppRelaunchCommands(executable: destination + "/Contents/MacOS/Visor",
                                        open: AppRelaunchCommands.opening(destination, sessions: "all", withoutAgent: false), agent: nil)
        try assertReads(appWatch(update: true, serving: true, window: false, commands: alone).script(), "an app with no agent")
    }

    /// Each word on its own too, as a command substitution's inside, where
    /// bash 3.2 went wrong.
    func testEachCommandReadsInsideASubstitution() throws {
        let each = commands
        for (name, words) in [("start", each.start), ("stop", each.stop), ("pid", each.pid), ("holder", each.holder),
                              ("appProcesses", each.appProcesses)] {
            try assertReads("x=$(\(words))\necho \"$x\"\n", name)
        }
    }

    /// The server agent's watch (kept one release, for the hand-back).
    func testTheServerAgentsWatchReadsUnderMacOSsShell() throws {
        let job = ServerAgentJob.job(bundleID: "com.LoganShire.Visor", home: "/Users/me", logs: "/Volumes/Visor/Logs")
        for update in [true, false] {
            let watch = ServerAgentWatch.launchd(job: job, serverPID: 4242, destination: destination, executable: "Visor",
                                                 source: update ? "/Users/me/Downloads/Visor.app" : nil,
                                                 backup: update ? support + "/Previous/abcd1234/Visor.app" : nil,
                                                 note: support + "/relaunch-rollback.txt", newVersion: "0.72.2", oldVersion: "0.72.1",
                                                 lock: support + "/relaunch-watch.lock")
            try assertReads(watch.script(), "the server agent's watch (update \(update))")
        }
    }

    /// `script` read by /bin/sh -n: it ends 0 and says nothing.
    private func assertReads(_ script: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("visor-watch-\(UUID().uuidString).sh").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(what): /bin/sh -n said: \(said)\n\(script)", file: file, line: line)
        XCTAssertEqual(said, "", "\(what)", file: file, line: line)
    }
}

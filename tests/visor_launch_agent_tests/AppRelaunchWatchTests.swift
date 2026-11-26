// The app's relaunch watch (AppRelaunchWatch, AppRelauncher's: from 0.72.1
// Visor.app's one update path), run for real as ServerAgentWatchTests run
// the server agent's: throwaway bundles whose "executable" is a shell
// script standing in for the app, which writes its pid to a stand-in
// instance lock (the app's process is the lock's holder, as Visor.app's
// is), and launchd played by a pid file. A new
// build that crashes, or runs and never answers, is undone: the previous
// bundle back, the rollback note written, the previous build started again.
// One that stays up is kept, and what it replaced removed. The watch waits
// for an answer from the new process whatever the app that went was doing
// (`served` starts at 0: until 0.72.1 a server that didn't listen on its
// port had it start at 1, and "never answered" couldn't be said).

import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Testing
import VisorLaunchAgent
import VisorServer

@Suite(.serialized) struct AppRelaunchWatchTests {
    /// A scratch folder, its stand-ins, and the watch's paths in it.
    private struct Scene {
        let root: String
        var destination: String { root + "/Visor.app" }
        var source: String { root + "/New.app" }
        var backup: String { root + "/Previous/token/Visor.app" }
        var note: String { root + "/relaunch-rollback.txt" }
        var pidFile: String { root + "/pid" }
        var answering: String { root + "/answering" }
        var started: String { root + "/started" }
        var lock: String { root + "/relaunch-watch.lock" }
        var present: String { root + "/com.LoganShire.Visor.present" }
        /// What the marker said as each start ran: "none", or its time.
        var seen: String { root + "/seen" }
        /// The stand-in instance lock: its holder's pid.
        var holder: String { root + "/instance.lock" }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-app-watch-" + UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        /// A stand-in app whose executable runs `body`, marked with `name`.
        func app(at path: String, name: String, body: String) throws {
            let macOS = path + "/Contents/MacOS"
            try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
            try StandIn.executable("#!/bin/sh\n\(body)\n", at: macOS + "/Visor")
            try name.write(toFile: path + "/name", atomically: true, encoding: .utf8)
        }

        /// An app whose server answers, one that crashes, and one that runs
        /// and never answers (no password, a server that never started).
        /// Each takes the stand-in lock as it starts, as Visor.app does, but
        /// the one that crashes before it's up.
        var serves: String { "echo $$ > '\(holder)'; touch '\(answering)'; exec sleep 60" }
        var crashes: String { "rm -f '\(answering)'; exit 1" }
        var crashesOnceUp: String { "echo $$ > '\(holder)'; touch '\(answering)'; sleep 2; exit 1" }
        var neverAnswers: String { "echo $$ > '\(holder)'; rm -f '\(answering)'; exec sleep 60" }

        /// The bundle the app was installed with: the new one, or the one
        /// before it.
        func install(backup: String) -> String {
            """
            mkdir -p '\((backup as NSString).deletingLastPathComponent)' && rm -rf '\(backup)'
            mv '\(destination)' '\(backup)' || exit 1
            cp -R '\(source)' '\(destination)' || exit 1
            """
        }

        /// The watch, launchd played: the app is the destination's
        /// executable, run in the background, its pid in a file; each start
        /// counted.
        func watch(update: Bool, beforeUndo: String = "", windowOpen: Bool = false, alsoStart: String = "",
                   appPID: Int32 = Scene.gonePID(), endWithin: Int = 60) -> AppRelaunchWatch {
            let start = "echo x >> '\(started)'; { cat '\(present)' 2>/dev/null || echo none; } >> '\(seen)'; rm -f '\(present)'; "
                + "( '\(destination)/Contents/MacOS/Visor' >/dev/null 2>&1 & echo $! > '\(pidFile)' )" + alsoStart
            return AppRelaunchWatch(appPID: appPID, destination: destination, backup: update ? backup : nil,
                                    install: update ? install(backup: backup) : "", start: start,
                                    stop: "\(beforeUndo)kill $(cat '\(pidFile)' 2>/dev/null) 2>/dev/null; rm -f '\(pidFile)'; sleep 0.2",
                                    // A zombie (a container's first process may reap nothing) is gone.
                                    // The lock's holder, while it runs.
                                    pid: "q=$(head -1 '\(holder)' 2>/dev/null | tr -dc 0-9); [ -n \"$q\" ] && kill -0 $q 2>/dev/null "
                                        + "&& ! grep -q '^State:.*Z' /proc/$q/status 2>/dev/null && echo $q",
                                    answers: "[ -f '\(answering)' ]", answersWhere: "at its socket file", note: note,
                                    newVersion: "0.72.2", oldVersion: "0.72.1", seconds: 4, firstAnswer: 4, appearWithin: 4,
                                    endWithin: endWithin, killAfter: 1, settle: 1, lock: lock, present: windowOpen ? present : nil)
        }

        /// A process that has ended: the app the watcher waits for.
        static func gonePID() -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "true"]
            try? process.run()
            process.waitUntilExit()
            return process.processIdentifier
        }

        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

        /// The stand-in app's process, running.
        var running: Bool {
            guard let pid = read(pidFile).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return false }
            return kill(pid, 0) == 0
        }

        /// How many times it was started.
        var starts: Int { read(started)?.split(separator: "\n").count ?? 0 }

        /// The watcher run to its end, its output read from a file. Spawned
        /// and waited for directly: Foundation's Process on Linux follows
        /// its child by a socket the child's children inherit, and the
        /// stand-in apps outlive the watcher.
        func run(_ watch: AppRelaunchWatch) throws -> String {
            let output = root + "/watch.out"
            var actions = posix_spawn_file_actions_t()
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
            let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", watch.script()].map { strdup($0) } + [nil]
            defer { for pointer in argv { free(pointer) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, "/bin/sh", &actions, nil, argv, environ)
            guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            return read(output) ?? ""
        }

        /// A watch with its defaults, and its script, to read.
        static func sampleWatch() -> AppRelaunchWatch {
            AppRelaunchWatch(appPID: 1, destination: "/Applications/Visor.app", backup: nil, install: "", start: "start", stop: "stop",
                             pid: "echo 2", answers: "true", answersWhere: "on port 7433", note: "/n", newVersion: "1", oldVersion: "1")
        }

        static func scriptSample() -> String { sampleWatch().script() }

        func cleanUp() {
            if let pid = read(pidFile).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    /// The build before, running, then the new one staged.
    private func update(_ scene: Scene, newBody: String) throws {
        try scene.app(at: scene.destination, name: "old", body: scene.serves)
        try scene.app(at: scene.source, name: "new", body: newBody)
    }

    @Test func aNewBuildThatNeverComesUpIsRolledBack() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.crashes)
        let output = try scene.run(scene.watch(update: true))
        #expect(output.contains("rolled back to 0.72.1: it never came up"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "old", "the previous build is back")
        #expect(scene.running, "and it was started again")
    }

    @Test func aNewBuildThatCrashesOnceUpIsRolledBack() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.crashesOnceUp)
        let output = try scene.run(scene.watch(update: true))
        #expect(output.contains("rolled back to 0.72.1: it quit or crashed"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "old", "the previous build is back")
        #expect(!FileManager.default.fileExists(atPath: scene.backup))
        #expect(!FileManager.default.fileExists(atPath: scene.root + "/Previous"), "nothing left behind")
        #expect(scene.read(scene.note) == "Visor Server 0.72.2 did not stay up after the update (it quit or crashed), so 0.72.1 was put back.\n")
        #expect(scene.running, "and it was started again")
        #expect(scene.starts == 2)
    }

    /// The bug before 0.72.1: an app that wasn't serving on its port had
    /// the watch take any running process as up. It must answer.
    @Test func aNewBuildThatRunsAndNeverAnswersIsRolledBack() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.neverAnswers)
        let output = try scene.run(scene.watch(update: true))
        #expect(output.contains("rolled back to 0.72.1: it never answered at its socket file"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "old")
        #expect(scene.read(scene.note) == "Visor Server 0.72.2 did not stay up after the update (it never answered at its socket file), so 0.72.1 was put back.\n")
        #expect(scene.running)
    }

    @Test func aNewBuildThatStaysUpIsKept() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.serves)
        let output = try scene.run(scene.watch(update: true))
        #expect(output.contains("0.72.2 stayed up"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "new")
        #expect(!FileManager.default.fileExists(atPath: scene.backup), "the build it replaced is gone once the new one stays up")
        #expect(!FileManager.default.fileExists(atPath: scene.root + "/Previous"))
        #expect(!FileManager.default.fileExists(atPath: scene.note))
        #expect(scene.running)
        #expect(scene.starts == 1, "started once")
        #expect(!FileManager.default.fileExists(atPath: scene.lock), "the watch's lock let go at its end")
    }

    @Test func aPlainRestartThatStaysUpIsLeftAlone() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "same", body: scene.serves)
        let output = try scene.run(scene.watch(update: false))
        #expect(output.contains("stayed up"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "same")
        #expect(scene.running)
    }

    @Test func aPlainRestartThatNeverAnswersIsStoppedAndStartedOnceMore() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "same", body: scene.neverAnswers)
        let output = try scene.run(scene.watch(update: false))
        #expect(output.contains("did not come up (it never answered at its socket file); starting it once more"), "\(output)")
        #expect(!FileManager.default.fileExists(atPath: scene.note), "nothing was put back")
        #expect(scene.starts == 2, "stopped, then started again: never two at once")
    }

    /// Another build put in place since this watch installed its own (a
    /// later update's): left as it is, the backup kept for whoever owns it.
    @Test func anUndoLeavesABundleItDidntInstall() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.crashes)
        let other = scene.root + "/Other.app"
        try scene.app(at: other, name: "later", body: scene.serves)
        let swap = "rm -rf '\(scene.destination)'; cp -R '\(other)' '\(scene.destination)'; "
        let output = try scene.run(scene.watch(update: true, beforeUndo: swap))
        #expect(output.contains("was left as it is"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "later", "the later update's bundle is untouched")
        #expect(scene.read(scene.backup + "/name") == "old", "and this watch's copy kept")
    }

    /// NCH's check of #537: launchd's copy coming up just after the
    /// fallback's open, and exiting 0 as a second instance, changed the
    /// process the watch looked at, and a healthy build was undone. The app
    /// is the lock's holder: a second copy that exits is never a crash.
    @Test func aSecondCopyThatExitsIsNoCrash() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.serves)
        // Another copy, which never takes the lock and goes after a moment.
        let second = "; ( sh -c 'sleep 3; exit 0' >/dev/null 2>&1 & )"
        let output = try scene.run(scene.watch(update: true, alsoStart: second))
        #expect(output.contains("0.72.2 stayed up"), "\(output)")
        #expect(!output.contains("rolled back"))
        #expect(scene.read(scene.destination + "/name") == "new")
    }

    /// NCH's check of #537: the instance lock's file keeps the id of a
    /// holder that has ended (the lock goes with its process, the file's
    /// words don't), and an id is reused. A live process by the id the file
    /// names that doesn't hold the lock isn't the app, so the fallback's
    /// open isn't skipped, nor a stranger watched or stopped; the process
    /// that holds it is (AppRelauncher's `holder`).
    @Test func aReusedProcessIDIsNoLockHolder() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        let holder = AppRelaunchWatch.lockHolder(scene.holder)
        // The holder gone, its id now another live process's, which never
        // took the lock.
        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stranger.arguments = ["60"]
        try stranger.run()
        defer { stranger.terminate() }
        try "\(stranger.processIdentifier)\n".write(toFile: scene.holder, atomically: true, encoding: .utf8)
        #expect(try Self.shell(holder) == "", "a live process by the id the file names, holding nothing, is no holder")
        // Taken, as the app takes it (its own id written in it): its holder.
        let lock = try #require(try InstanceLock.take(scene.holder))
        #expect(try Self.shell(holder) == "\(getpid())\n")
        #expect(InstanceLock.isHeld(scene.holder) && InstanceLock.holder(scene.holder) == getpid(), "asking let nothing go")
        lock.release()
        #expect(try Self.shell(holder) == "", "let go: this process runs still, but holds nothing")
        #expect(FileManager.default.fileExists(atPath: scene.holder), "the file is kept")
        try FileManager.default.removeItem(atPath: scene.holder)
        #expect(try Self.shell(holder) == "", "no file: no holder")
    }

    /// What `command` prints, run by /bin/sh.
    private static func shell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// NCH's check of #537: an app whose quit never ends (a modal, a
    /// terminate not answered) left no server and the watch's lock held. It
    /// has `endWithin` seconds, then TERM, then KILL.
    @Test func anAppThatDoesntEndIsStopped() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "same", body: scene.serves)
        let stuck = Process()
        stuck.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stuck.arguments = ["300"]
        try stuck.run()
        let output = try scene.run(scene.watch(update: false, appPID: stuck.processIdentifier, endWithin: 1))
        #expect(output.contains("the app (process \(stuck.processIdentifier)) didn't end within 1 s: sent TERM"), "\(output)")
        #expect(output.contains("stayed up"), "and the app was started once it had gone")
        stuck.waitUntilExit()
        #expect(stuck.terminationReason == .uncaughtSignal, "ended by the watcher's TERM")
    }

    /// NCH's check of #537: a build that runs and never answers left the
    /// Mac with no server for about twelve minutes before it was undone.
    /// Two minutes once its process is up; ten only while none has appeared.
    @Test func aRunningBuildHasTwoMinutesToAnswer() {
        let watch = Scene.sampleWatch()
        #expect(watch.firstAnswer == 120)
        #expect(watch.appearWithin == 600)
        #expect(watch.endWithin == 60 && watch.killAfter == 10)
        let script = watch.script()
        #expect(script.contains("[ $i -ge 60 ]"), "two minutes of looks two seconds apart")
        #expect(script.contains("[ $waited -ge 300 ]"), "ten, before any process")
    }

    /// An update gives back the window it found (Logan, 25 Nov 2026): with
    /// one open as the app went, the marker that has the app show it is
    /// written just before each start; with none, nothing is, and the new
    /// build keeps to the menu bar.
    @Test func aWindowOpenAsTheAppWentIsShownAgain() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.crashes)
        let before = Int(Date().timeIntervalSince1970)
        _ = try scene.run(scene.watch(update: true, windowOpen: true))
        let seen = (scene.read(scene.seen) ?? "").split(separator: "\n").map(String.init)
        #expect(seen.count == 2, "the new build's start, and the rollback's")
        for time in seen {
            let asked = try #require(AppAgentJob.askedAt(time), "the marker was there at each start: \(seen)")
            #expect(asked >= before && AppAgentJob.showsWindow(fromAgent: true, askedAt: asked, now: Int(Date().timeIntervalSince1970)))
        }
    }

    @Test func noWindowOpenKeepsTheNewBuildInTheMenuBar() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.serves)
        let output = try scene.run(scene.watch(update: true, windowOpen: false))
        #expect(output.contains("stayed up"), "\(output)")
        #expect(scene.read(scene.seen) == "none\n", "no marker at its start")
        #expect(!AppAgentJob.showsWindow(fromAgent: true, askedAt: nil, now: Int(Date().timeIntervalSince1970)))
    }

    /// What the app's own watch asks on a Mac: the port from the new
    /// process itself, or the socket file when it doesn't listen yet.
    @Test func itAsksThePortFromTheNewProcessOrTheSocketFile() {
        let port = AppRelaunchWatch.portAnswers(7433)
        #expect(port.contains("http://127.0.0.1:7433/api/hello"))
        #expect(port.contains("lsof -nP -t -iTCP:7433 -sTCP:LISTEN") && port.contains("grep -qx \"$p\""), "from the new process alone")
        let socket = AppRelaunchWatch.socketAnswers("/Volumes/Visor/run/server.sock")
        #expect(socket.contains("--unix-socket '/Volumes/Visor/run/server.sock' http://localhost/api/hello"))
        let script = Scene.scriptSample()
        #expect(script.contains("served=0;"), "an answer is waited for, whatever the app was doing")
        #expect(!script.contains("served=1; i=0"))
    }
}

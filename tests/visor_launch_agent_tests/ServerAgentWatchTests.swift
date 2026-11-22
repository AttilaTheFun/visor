// The server agent's restart watch, run for real (as AppRelauncherTests
// run the app's): throwaway bundles whose "executable" is a shell script
// standing in for the server, and launchd played by a pid file. A new
// build that crashes, or never answers, is undone: the previous bundle and
// plist back, the rollback note written, the previous build started again.
// One that stays up is kept, and what it replaced removed.

import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Testing
@testable import VisorLaunchAgent
import VisorServer

@Suite(.serialized) struct ServerAgentWatchTests {
    /// A scratch folder, its stand-ins, and the watch's paths in it.
    private struct Scene {
        let root: String
        var destination: String { root + "/Visor.app" }
        var source: String { root + "/New.app" }
        var backup: String { root + "/Previous/Visor.app" }
        var plist: String { root + "/server.plist" }
        var previousPlist: String { root + "/server.plist.previous" }
        var note: String { root + "/relaunch-rollback.txt" }
        var pidFile: String { root + "/pid" }
        var answering: String { root + "/answering" }
        var lock: String { root + "/relaunch-watch.lock" }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-agent-watch-" + UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        /// A stand-in app whose executable runs `body`, marked with `name`.
        func app(at path: String, name: String, body: String) throws {
            let macOS = path + "/Contents/MacOS"
            try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
            try "#!/bin/sh\n\(body)\n".write(toFile: macOS + "/run", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS + "/run")
            try name.write(toFile: path + "/name", atomically: true, encoding: .utf8)
        }

        /// A server that answers, and one that crashes, or runs and never
        /// answers.
        var serves: String { "touch '\(answering)'; exec sleep 60" }
        var crashes: String { "rm -f '\(answering)'; exit 1" }
        var neverAnswers: String { "rm -f '\(answering)'; exec sleep 60" }

        /// The watch, launchd played: the job is the destination's
        /// executable, run in the background, its pid in a file.
        func watch(source: String?, previousPlist: String?, beforeUndo: String = "") -> ServerAgentWatch {
            let start = "( '\(destination)/Contents/MacOS/run' >/dev/null 2>&1 & echo $! > '\(pidFile)' )"
            return ServerAgentWatch(serverPID: Self.gonePID(), destination: destination, source: source,
                                    backup: source == nil ? nil : backup, plist: plist, previousPlist: previousPlist, start: start, reload: start,
                                    stop: "\(beforeUndo)kill $(cat '\(pidFile)' 2>/dev/null) 2>/dev/null; rm -f '\(pidFile)'; sleep 0.2",
                                    // A zombie (a container's first process may reap nothing) is gone.
                                    pid: "q=$(cat '\(pidFile)' 2>/dev/null); [ -n \"$q\" ] && kill -0 $q 2>/dev/null "
                                        + "&& ! grep -q '^State:.*Z' /proc/$q/status 2>/dev/null && echo $q",
                                    answers: "[ -f '\(answering)' ]", note: note, newVersion: "0.62.5", oldVersion: "0.62.4",
                                    seconds: 4, firstAnswer: 4, settle: 1, lock: lock, bundleExecutable: "Contents/MacOS/run")
        }

        /// A process that has ended: the server the watcher waits for.
        static func gonePID() -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "true"]
            try? process.run()
            process.waitUntilExit()
            return process.processIdentifier
        }

        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

        /// The stand-in job's process, running.
        var running: Bool {
            guard let pid = read(pidFile).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return false }
            return kill(pid, 0) == 0
        }

        /// The watcher run to its end, its output read from a file. Spawned
        /// and waited for directly: Foundation's Process on Linux follows
        /// its child by a socket the child's children inherit, and the
        /// stand-in servers outlive the watcher.
        func run(_ watch: ServerAgentWatch) throws -> String {
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

        func cleanUp() {
            if let pid = read(pidFile).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    /// The previous build and its plist, then the new one staged.
    private func update(_ scene: Scene, newBody: String) throws {
        try scene.app(at: scene.destination, name: "old", body: scene.serves)
        try scene.app(at: scene.source, name: "new", body: newBody)
        try "old plist".write(toFile: scene.previousPlist, atomically: true, encoding: .utf8)
        try "new plist".write(toFile: scene.plist, atomically: true, encoding: .utf8)
    }

    @Test func aNewBuildThatCrashesIsRolledBack() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.crashes)
        let output = try scene.run(scene.watch(source: scene.source, previousPlist: scene.previousPlist))
        #expect(output.contains("rolled back to 0.62.4: it quit or crashed"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "old", "the previous build is back")
        #expect(scene.read(scene.plist) == "old plist", "and its plist")
        #expect(!FileManager.default.fileExists(atPath: scene.backup))
        #expect(!FileManager.default.fileExists(atPath: scene.root + "/Previous"), "nothing left behind")
        #expect(!FileManager.default.fileExists(atPath: scene.previousPlist))
        #expect(scene.read(scene.note) == "Visor Server 0.62.5 did not stay up after the update (it quit or crashed), so 0.62.4 was put back.\n")
        #expect(scene.running, "and the job was started again")
    }

    @Test func aNewBuildThatNeverAnswersIsRolledBack() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.neverAnswers)
        let output = try scene.run(scene.watch(source: scene.source, previousPlist: scene.previousPlist))
        #expect(output.contains("rolled back to 0.62.4: it never answered on port 7433"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "old")
        #expect(scene.read(scene.plist) == "old plist")
        #expect(scene.running)
    }

    @Test func aNewBuildThatStaysUpIsKept() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.serves)
        let output = try scene.run(scene.watch(source: scene.source, previousPlist: scene.previousPlist))
        #expect(output.contains("0.62.5 stayed up"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "new")
        #expect(scene.read(scene.plist) == "new plist")
        #expect(!FileManager.default.fileExists(atPath: scene.backup), "the build it replaced is gone once the new one stays up")
        #expect(!FileManager.default.fileExists(atPath: scene.root + "/Previous"))
        #expect(!FileManager.default.fileExists(atPath: scene.previousPlist))
        #expect(!FileManager.default.fileExists(atPath: scene.note))
        #expect(scene.running)
    }

    @Test func aPlainRestartThatStaysUpIsLeftAlone() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "same", body: scene.serves)
        try "plist".write(toFile: scene.plist, atomically: true, encoding: .utf8)
        let output = try scene.run(scene.watch(source: nil, previousPlist: nil))
        #expect(output.contains("stayed up"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "same")
        #expect(scene.running)
    }

    @Test func aPlainRestartThatDoesntComeUpIsStartedOnceMore() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "same", body: scene.crashes)
        let output = try scene.run(scene.watch(source: nil, previousPlist: nil))
        #expect(output.contains("did not come up (it quit or crashed); starting it once more"), "\(output)")
        #expect(!FileManager.default.fileExists(atPath: scene.note), "nothing was put back")
    }

    // NCH's check of #491: an update 43 seconds after another, the first
    // one's watcher still watching, undid over the second's install and
    // left no Visor.app at all.

    /// Its own copy of the previous build gone by the time it would undo:
    /// the bundle in place is left as it is.
    @Test func anUndoWithItsBackupGoneLeavesTheBundleInPlace() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try update(scene, newBody: scene.crashes)
        let output = try scene.run(scene.watch(source: scene.source, previousPlist: nil, beforeUndo: "rm -rf '\(scene.backup)'; "))
        #expect(output.contains("was left as it is"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "new", "nothing removed")
        #expect(!FileManager.default.fileExists(atPath: scene.note), "nothing said put back")
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
        let output = try scene.run(scene.watch(source: scene.source, previousPlist: nil, beforeUndo: swap))
        #expect(output.contains("was left as it is"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "later", "the later update's bundle is untouched")
        #expect(scene.read(scene.backup + "/name") == "old", "and this watch's copy kept")
    }

    /// Back to back: a watch still holding the lock is stopped by the next
    /// one, which holds it while it watches and lets it go at its end.
    @Test func aSecondWatchStopsTheFirstAndHoldsTheLock() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        let earlier = Process()
        earlier.executableURL = URL(fileURLWithPath: "/bin/sh")
        earlier.arguments = ["-c", RelaunchWatchLock.take(scene.lock) + "\nexec sleep 60"]
        try earlier.run()
        for _ in 0..<50 where scene.read(scene.lock) == nil { Thread.sleep(forTimeInterval: 0.1) }
        let held = try #require(scene.read(scene.lock).flatMap(RelaunchWatchLock.read))
        #expect(held.pid == earlier.processIdentifier)
        try scene.app(at: scene.destination, name: "same", body: scene.serves)
        let output = try scene.run(scene.watch(source: nil, previousPlist: nil))
        #expect(output.contains("stopping the watch of an earlier update (process \(earlier.processIdentifier))"), "\(output)")
        earlier.waitUntilExit()
        #expect(output.contains("stayed up"))
        #expect(!FileManager.default.fileExists(atPath: scene.lock), "let go at its end")
    }

    @Test func theLockSaysWhoHoldsItAndForHowLong() {
        #expect(RelaunchWatchLock.read("4242 1795000000\n")?.pid == 4242)
        #expect(RelaunchWatchLock.read("nonsense") == nil)
        #expect(RelaunchWatchLock.remaining("4242 1795000000", now: 1_795_000_100, isRunning: { $0 == 4242 }) == 620)
        #expect(RelaunchWatchLock.remaining("4242 1795000000", now: 1_795_000_100, isRunning: { _ in false }) == nil, "a watcher gone holds nothing")
        #expect(RelaunchWatchLock.remaining(nil, now: 0, isRunning: { _ in true }) == nil)
        #expect(RelaunchWatchLock.remaining("4242 1795000000", now: 1_795_009_999, isRunning: { _ in true }) == 5)
    }

    @Test func theLaunchdWatchKickstartsARestartAndRegistersAfreshAfterAnUpdateOrARollback() {
        let job = ServerAgentJob.job(bundleID: "com.LoganShire.Visor", home: "/Users/me")
        let register = "'/Applications/Visor.app/Contents/MacOS/Visor' server-agent register"
        #expect(ServerAgentWatch.registerCommand(destination: "/Applications/Visor.app", executable: "Visor") == register)
        let restart = ServerAgentWatch.launchd(job: job, serverPID: 1, destination: "/Applications/Visor.app", executable: "Visor",
                                               source: nil, backup: nil, note: "/n", newVersion: "1", oldVersion: "1")
        #expect(restart.start == "launchctl kickstart -k gui/$(id -u)/com.LoganShire.Visor.server 2>/dev/null || " + register)
        // Another build in place, or the one before put back: booted out and
        // registered again (`server-agent register`), never a kickstart.
        let update = ServerAgentWatch.launchd(job: job, serverPID: 1, destination: "/Applications/Visor.app", executable: "Visor",
                                              source: "/tmp/New/Visor.app", backup: "/tmp/Previous/Visor.app", note: "/n",
                                              newVersion: "2", oldVersion: "1")
        #expect(update.start == register)
        #expect(update.reload == register)
        #expect(restart.reload == register)
        #expect(update.previousPlist == nil, "the plist is the bundle's: it comes back with it")
        let script = update.script()
        #expect(!script.contains("bootstrap"))
        #expect(script.contains("while kill -0 1 2>/dev/null"), "it waits for the server to go first")
        // The rollback: the bundle put back before it's registered afresh.
        let undo = script.components(separatedBy: "rolled back")[0]
        let putBack = undo.range(of: "mv '/tmp/Previous/Visor.app' '/Applications/Visor.app'")
        let registered = script.range(of: register, options: .backwards)
        #expect(putBack != nil && registered != nil && putBack!.lowerBound < registered!.lowerBound)
    }
}

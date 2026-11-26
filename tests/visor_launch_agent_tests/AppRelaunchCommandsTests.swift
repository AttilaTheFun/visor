// What the app's relaunch watch runs on a Mac to start, stop and find
// Visor.app (AppRelaunchCommands, AppRelauncher's), run for real in the
// watch with stand-ins: a throwaway bundle whose "executable" is a shell
// script that answers `app-agent start` as Visor.app does (launchd played:
// the app started in the background by a path relative to the bundle, as
// BundleProgram runs it, and the command ending 0 once it holds its
// instance lock, 1 if it never does), and launchctl played by a script that
// says what it was asked. Until 0.72.2 the watch's tests ran stand-ins for
// these words alone, and the words themselves were never run (NCH's lease
// test of 0.72.1: the watcher died of a syntax error in them under macOS's
// /bin/sh, which the Mac's tests now read: visor_launch_agent_mac_tests).

import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Testing
import VisorLaunchAgent
import VisorServer

@Suite(.serialized) struct AppRelaunchCommandsTests {
    /// A scratch folder, its stand-ins, and the watch's paths in it.
    private struct Scene {
        let root: String
        var destination: String { root + "/Visor.app" }
        var source: String { root + "/New.app" }
        var backup: String { root + "/Previous/token/Visor.app" }
        var executable: String { destination + "/Contents/MacOS/Visor" }
        var note: String { root + "/relaunch-rollback.txt" }
        var answering: String { root + "/answering" }
        var lock: String { root + "/relaunch-watch.lock" }
        /// The instance lock: its holder's pid on its first line.
        var instance: String { root + "/instance.lock" }
        /// What the stand-in launchctl was asked, a line each time.
        var asked: String { root + "/launchctl.log" }
        var launchctl: String { root + "/launchctl" }
        /// Each start through `app-agent start`, a line each.
        var started: String { root + "/started" }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-app-commands-" + UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try StandIn.executable("#!/bin/sh\necho \"$*\" >> '\(asked)'\n", at: launchctl)
        }

        /// A stand-in Visor.app: `app-agent start` starts the bundle's own
        /// executable as launchd does (from the bundle, by a relative
        /// path) and ends 0 once it holds the instance lock; run alone, it
        /// is the app and runs `body`.
        func app(at path: String, name: String, body: String) throws {
            let macOS = path + "/Contents/MacOS"
            try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
            let holder = AppRelaunchWatch.lockHolder(instance)
            let script = """
            #!/bin/sh
            if [ "$1" = app-agent ]; then
              echo x >> '\(started)'
              bundle=$(cd "$(dirname "$0")/../.." && pwd)
              ( cd "$bundle" && exec Contents/MacOS/Visor >/dev/null 2>&1 & )
              n=0; while [ $n -lt 25 ]; do [ -n "$(\(holder))" ] && exit 0; sleep 0.2; n=$((n+1)); done; exit 1
            fi
            \(body)
            """
            try StandIn.executable(script, at: macOS + "/Visor")
            try name.write(toFile: path + "/name", atomically: true, encoding: .utf8)
        }

        /// The app taking its instance lock as Visor.app does (flock, its
        /// pid on the first line), then serving.
        var takesTheLock: String { "exec 9>>'\(instance)'; flock -n 9 || exit 0; echo $$ > '\(instance)'" }
        /// Not `exec sleep`: the process stays the app, by the path it was
        /// run by.
        var serves: String { "\(takesTheLock); touch '\(answering)'; while :; do sleep 1; done" }
        var crashesOnceUp: String { "\(takesTheLock); touch '\(answering)'; sleep 3; exit 1" }

        /// What the watch runs, as AppRelauncher gives it, launchctl played.
        var commands: AppRelaunchCommands {
            AppRelaunchCommands(executable: executable, open: "echo opened >> '\(started)'",
                                agent: .init(label: "com.LoganShire.Visor.app", command: ["app-agent", "start"], instanceLock: instance),
                                launchctl: launchctl)
        }

        func watch(update: Bool, appearWithin: Int = 4) -> AppRelaunchWatch {
            let app = commands
            return AppRelaunchWatch(appPID: Self.gonePID(), destination: destination, backup: update ? backup : nil,
                                    install: update ? AppRelaunchCommands.replacing(destination, with: source, keptAt: backup, sessions: "all") : "",
                                    start: app.start, stop: app.stop, pid: app.pid,
                                    answers: "[ -f '\(answering)' ]", answersWhere: "at its socket file", note: note,
                                    newVersion: "0.72.3", oldVersion: "0.72.2", seconds: 10, firstAnswer: 4, appearWithin: appearWithin,
                                    endWithin: 60, killAfter: 1, settle: 1, lock: lock)
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

        /// The instance lock's holder, as the watch asks it.
        var holder: Int32? {
            Int32((try? AppRelaunchCommandsTests.shell(AppRelaunchWatch.lockHolder(instance)))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }

        /// How many times it was started through `app-agent start`.
        var starts: Int { read(started)?.split(separator: "\n").filter { $0 == "x" }.count ?? 0 }

        /// The watcher run to its end, its output read from a file (spawned
        /// and waited for directly, as AppRelaunchWatchTests does: the
        /// stand-in apps outlive it).
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

        func cleanUp() {
            if let pid = holder { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    /// What `command` prints, run by /bin/sh: spawned and waited for
    /// directly, its output read from a file, as the watcher is (`run`):
    /// Foundation's Process on Linux follows its child by a socket the
    /// child's children inherit, and the app a start leaves running would
    /// hold it open.
    static func shell(_ command: String) throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("visor-app-commands-\(UUID().uuidString).out").path
        defer { try? FileManager.default.removeItem(atPath: output) }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, nil, argv, environ)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
    }

    /// The 0.72.x to 0.72.y update, both sides this watcher: started
    /// through `app-agent start`, launchd's copy (run by a relative path)
    /// followed by its pid, and kept.
    @Test func aNewBuildStartedThroughItsAgentAndFollowedByItsPIDIsKept() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "old", body: scene.serves)
        try scene.app(at: scene.source, name: "new", body: scene.serves)
        let output = try scene.run(scene.watch(update: true))
        #expect(output.contains("0.72.3 stayed up"), "\(output)")
        #expect(!output.contains("opened instead") && !output.contains("rolled back"), "\(output)")
        #expect(scene.read(scene.destination + "/name") == "new")
        #expect(!FileManager.default.fileExists(atPath: scene.backup), "the build it replaced is removed")
        #expect(scene.starts == 1)
        #expect(scene.holder != nil, "launchd's copy runs on")
    }

    /// A crash once up (launchd's restart would be another process): the
    /// agent booted out, the holder stopped by its pid, the previous build
    /// back and started through its own `app-agent start`.
    @Test func aNewBuildThatCrashesOnceUpIsRolledBackThroughTheRealStop() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "old", body: scene.serves)
        try scene.app(at: scene.source, name: "new", body: scene.crashesOnceUp)
        let output = try scene.run(scene.watch(update: true))
        #expect(output.contains("rolled back to 0.72.2: it quit or crashed"), "\(output)")
        #expect(output.contains("launchctl bootout com.LoganShire.Visor.app: status 0"), "\(output)")
        #expect(scene.read(scene.asked)?.contains("bootout gui/\(getuid())/com.LoganShire.Visor.app") == true)
        #expect(scene.read(scene.destination + "/name") == "old", "the previous build is back")
        #expect(scene.read(scene.note) == "Visor Server 0.72.3 did not stay up after the update (it quit or crashed), so 0.72.2 was put back.\n")
        #expect(scene.starts == 2, "the new build's start, and the previous one's")
        #expect(scene.holder != nil, "the previous build runs")
    }

    /// NCH's lease test of 0.72.1: a bundle that doesn't run at all (it
    /// exits 3) was opened instead, then nothing: no rollback, no Visor,
    /// the broken bundle left in place. Its `app-agent start` ending 3 says
    /// so, and it's undone at once, not after ten minutes' wait for a
    /// process.
    @Test func aBuildThatDoesntRunAtAllIsRolledBackAtOnce() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "old", body: scene.serves)
        try scene.app(at: scene.source, name: "new", body: "")
        // Not even `app-agent start`: the whole executable ends 3.
        try StandIn.executable("#!/bin/sh\nexit 3\n", at: scene.source + "/Contents/MacOS/Visor")
        let began = Date()
        let output = try scene.run(scene.watch(update: true, appearWithin: 60))
        #expect(output.contains("app-agent start ended with status 3: the build doesn't run"), "\(output)")
        #expect(output.contains("rolled back to 0.72.2: it didn't run (app-agent start ended with status 3)"), "\(output)")
        #expect(!output.contains("opened instead"), "no open of a build that can't run")
        #expect(Date().timeIntervalSince(began) < 30, "undone at once")
        #expect(scene.read(scene.destination + "/name") == "old")
        #expect(scene.read(scene.note)?.contains("(it didn't run (app-agent start ended with status 3))") == true)
        #expect(scene.holder != nil, "the previous build was started again")
    }

    /// The app is followed by its pid: launchd's copy, run by the relative
    /// `Contents/MacOS/Visor`, is the lock's holder (the watch's `pid`),
    /// which no search by the bundle's full path finds (NCH's same test).
    @Test func launchdsCopyIsFoundByItsPIDNotItsPath() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        try scene.app(at: scene.destination, name: "same", body: scene.serves)
        #expect(try Self.shell(scene.commands.start + "\necho \"why=$why\"") == "why=\n", "started through launchd, nothing to say")
        let holder = try #require(scene.holder, "launchd's copy holds the lock")
        #expect(try Self.shell(scene.commands.pid) == "\(holder)\n")
        #expect(try Self.shell("cat /proc/\(holder)/cmdline 2>/dev/null | tr '\\0' ' '").contains(" Contents/MacOS/Visor"),
                "run by the relative path, as launchd runs it")
        _ = try Self.shell(scene.commands.stop)
        // Not `kill -0`: in a container whose first process reaps nothing,
        // it stays a zombie; the lock goes with it all the same.
        #expect(scene.holder == nil, "and stopped by its pid")
    }

    /// The copies the stop looks for by the bundle's full path (the
    /// fallback's open): the app itself, alone or with its launch's
    /// arguments; never its agents or the watcher's own shell.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/pgrep") && FileManager.default.isExecutableFile(atPath: "/bin/bash")))
    func theOpenedCopyIsFoundByItsFullPath() throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        let exe = scene.executable
        func process(_ argv0: String) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "exec -a \(AppRelaunchWatch.quoted(argv0)) sleep 60"]
            try process.run()
            return process
        }
        let opened = try process(exe + " --resume-sessions")
        let server = try process(exe + " --server")
        let proxy = try process(exe + " --agent-proxy")
        let relative = try process("Contents/MacOS/Visor")
        defer { for each in [opened, server, proxy, relative] { each.terminate() } }
        Thread.sleep(forTimeInterval: 0.3)
        let found = try Self.shell(scene.commands.appProcesses).split(separator: "\n").map(String.init)
        #expect(found == ["\(opened.processIdentifier)"], "\(found)")
    }
}

// What the app's relaunch watch (AppRelaunchWatch) runs on a Mac to start,
// stop and find Visor.app (AppRelauncher's), as shell: here, apart from
// AppKit, so the same words run in the tests on Linux, with stand-ins for
// launchctl and the app (//tests/visor_launch_agent_tests), and go through
// macOS's own /bin/sh in the Mac's (//tests/visor_launch_agent_tests:
// visor_launch_agent_mac_tests).
//
// macOS's /bin/sh is bash 3.2, which reads a case's `pattern)` inside
// `$( … )` as the substitution's end and stops the whole script with a
// syntax error (NCH's lease test of 0.72.1: the watcher died at line 48,
// so it neither said a build stayed up nor rolled a broken one back).
// Each pattern here is written `(pattern)`, which it reads as meant.
//
// The app is followed by its process id, never by its command line:
// launchd runs it by a path relative to the bundle (BundleProgram,
// `Contents/MacOS/Visor`), which no search by the bundle's full path finds
// (NCH's same test). Its id is the instance lock's holder (the lock file's
// first line, while it's held: the app writes it as it takes the lock,
// however it was started). The full path finds only a copy that was
// opened (the fallback's `open -a`), to stop it.
//
// A Quit is told from a crash by a marker the app writes as AppKit ends it
// (AppAgentJob.quitMarker: its own pid), not by launchd's word: `launchctl
// print`'s "last exit code" is a job's, not a process's (the fallback's
// opened copy is no job's, and a registration afresh, as `app-agent start`
// makes, starts the job over), and launchctl's own manual says that output
// "is NOT API in any sense at all". The marker names the very process the
// watch follows, by the pid it follows it by, and the tests run it as they
// run the rest.

import Foundation

public struct AppRelaunchCommands: Sendable {
    /// The app's own launchd agent.
    public struct Agent: Sendable {
        /// Its launchd label (`com.LoganShire.Visor.app`).
        public var label: String
        /// The app's command that starts it from the bundle in place
        /// (`app-agent start`): exits 0 once launchd runs the app, 1 when it
        /// doesn't.
        public var command: [String]
        /// The app's instance lock, whose first line is its holder's pid.
        public var instanceLock: String?
        /// The marker of a Quit, whose first line is the pid of the app
        /// that quit (AppAgentJob.quitMarker); nil: none, and any end is
        /// taken for a failure.
        public var quitMarker: String?

        public init(label: String, command: [String], instanceLock: String? = nil, quitMarker: String? = nil) {
            self.label = label
            self.command = command
            self.instanceLock = instanceLock
            self.quitMarker = quitMarker
        }
    }

    /// The app's executable, in the bundle in place.
    public var executable: String
    /// Shell: the app opened (`open -a …`).
    public var open: String
    /// The app's agent, if it has one; nil: opened alone.
    public var agent: Agent?
    /// launchctl (a test's stand-in).
    public var launchctl: String

    public init(executable: String, open: String, agent: Agent?, launchctl: String = "launchctl") {
        self.executable = executable
        self.open = open
        self.agent = agent
        self.launchctl = launchctl
    }

    /// Shell: the app started, through its agent when it has one (`open -a`
    /// when that doesn't start it), else opened. `app-agent start` ends 0
    /// or 1; any other end (an exit of 3, a crash) is the new build's own
    /// executable not running at all, which no open would mend: `why` says
    /// so, and the watch undoes it at once rather than wait ten minutes for
    /// a process that never comes (NCH's same test: a broken bundle was
    /// opened instead, then nothing).
    public var start: String {
        guard let agent else { return open }
        let command = ([executable] + agent.command).map(AppRelaunchWatch.quoted).joined(separator: " ")
        // Its copy may come up after `app-agent start` has given up: then
        // it runs, and no second is opened. A Quit's marker from before is
        // taken away first: only the app this start brings writes the next.
        let forget = agent.quitMarker.map { "rm -f \(AppRelaunchWatch.quoted($0)); " } ?? ""
        return """
        \(forget)\(command); st=$?
        if [ $st = 0 ]; then :
        elif [ $st != 1 ]; then why="it didn't run (app-agent start ended with status $st)"; echo "$(date): \(agent.command.first ?? "app-agent") start ended with status $st: the build doesn't run"
        elif [ -n "$(\(holder))" ]; then echo "$(date): launchd's copy came up after all"
        else echo "$(date): launchd didn't start it: opened instead"; \(open); fi
        """
    }

    /// Shell: the app stopped: its agent out of launchd first (so KeepAlive
    /// starts nothing while the bundle is put back; what launchctl said is
    /// logged; the bootout ends launchd's process, the lock's or not), then
    /// the app's process (the instance lock's holder: TERM, then KILL), and
    /// anything else running from the bundle as the app (the fallback's
    /// open, by its full path). One that can't be stopped is said to run
    /// still, never passed over.
    public var stop: String {
        let others = "for q in $(\(appProcesses)); do kill $q 2>/dev/null; done"
        guard let agent else { return "\(others); sleep 2; for q in $(\(appProcesses)); do kill -9 $q 2>/dev/null; done" }
        return """
        out=$(\(launchctl) bootout gui/$(id -u)/\(agent.label) 2>&1); st=$?; echo "$(date): launchctl bootout \(agent.label): status $st${out:+: $out}"
        q=$(\(holder)); if [ -n "$q" ]; then kill $q 2>/dev/null; n=0; while kill -0 $q 2>/dev/null && [ $n -lt 50 ]; do sleep 0.2; n=$((n+1)); done; kill -0 $q 2>/dev/null && kill -9 $q 2>/dev/null; sleep 0.5; kill -0 $q 2>/dev/null && echo "$(date): the app (process $q) couldn't be stopped: it still runs"; fi
        \(others)
        """
    }

    /// Shell: succeeds when the app's process the watch followed (`$first`)
    /// ended at a Quit: the marker names it. Without a marker, never.
    public var quit: String {
        guard let marker = agent?.quitMarker else { return "false" }
        return "[ -n \"$first\" ] && [ \"$(head -1 \(AppRelaunchWatch.quoted(marker)) 2>/dev/null | tr -dc 0-9)\" = \"$first\" ]"
    }

    /// Shell: the app's process id: the instance lock's holder, while it
    /// holds the lock (a second copy that loses the race and exits 0 is
    /// never it); without one (an app with no lock), the first process of
    /// the bundle's that is the app.
    public var pid: String {
        guard agent?.instanceLock != nil else { return "\(appProcesses) | head -1" }
        return holder
    }

    /// Shell: the instance lock's holder, while it holds the lock, else
    /// nothing: a process that merely has the id the file names (reused
    /// since its holder ended) is none (AppRelaunchWatch.lockHolder).
    public var holder: String {
        guard let lock = agent?.instanceLock else { return "true" }
        return AppRelaunchWatch.lockHolder(lock)
    }

    /// Shell: the processes running `executable` by its full path as the
    /// app: by itself or with its launch's arguments (`--resume-sessions`),
    /// not as one of its agents (`--server`, `--agent-proxy`) or commands
    /// (a word), nor any process that merely names it (this watcher's own
    /// shell). Each case pattern in parentheses, for bash 3.2.
    public var appProcesses: String {
        let exe = AppRelaunchWatch.quoted(executable)
        return "pgrep -f \(exe) | while read q; do case \"$(ps -o args= -p $q 2>/dev/null)\" in "
            + "(\(exe)' --server'*|\(exe)' --agent-proxy'*) ;; (\(exe)|\(exe)' -'*) echo $q;; esac; done"
    }

    /// Shell: the running bundle moved aside to `kept` (not removed: it's
    /// what comes back if the new one fails) and `source` copied in its
    /// place; if that can't be done, the running one put back and opened.
    public static func replacing(_ destination: String, with source: String, keptAt kept: String, sessions: String) -> String {
        let q = AppRelaunchWatch.quoted
        return """
        mkdir -p \(q((kept as NSString).deletingLastPathComponent)) && rm -rf \(q(kept))
        mv \(q(destination)) \(q(kept)) || exit 1
        cp -R \(q(source)) \(q(destination)) || { rm -rf \(q(destination)); mv \(q(kept)) \(q(destination)); open -a \(q(destination)) --args --resume-sessions \(q(sessions)); exit 1; }

        """
    }

    /// Shell: the app opened. With an agent it's the fallback once launchd
    /// didn't start the app: it says so (`--without-agent`), and the app
    /// runs where it is rather than ask launchd again; in the background
    /// (`-g`), the window, mid-update, being the present marker's to ask
    /// for alone.
    public static func opening(_ destination: String, sessions: String, withoutAgent: Bool) -> String {
        "open \(withoutAgent ? "-g " : "")-a \(AppRelaunchWatch.quoted(destination)) --args --resume-sessions \(AppRelaunchWatch.quoted(sessions))"
            + (withoutAgent ? " \(Self.withoutAgent)" : "")
    }

    /// The argument of an open that comes after launchd didn't start the
    /// app as its agent (AppRelauncher.withoutAgent).
    public static let withoutAgent = "--without-agent"

    /// Shell: a build that came as a download (a Taildrop, a browser)
    /// carries the quarantine through its bundle, and its first open waits
    /// on the system's "downloaded from the Internet" question on the Mac's
    /// screen, the server not running meanwhile: lifted, once the system
    /// accepts the build (notarized, Developer ID).
    public static func accept(_ destination: String) -> String {
        let bundle = AppRelaunchWatch.quoted(destination)
        return "spctl --assess --type execute \(bundle) >/dev/null 2>&1 && xattr -rd com.apple.quarantine \(bundle) 2>/dev/null"
    }
}

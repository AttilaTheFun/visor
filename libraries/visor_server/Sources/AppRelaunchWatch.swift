// The app's relaunch and its watch, as a shell script (AppRelauncher, the
// menu bar app's ServerLifecycle; from 0.72.1 Visor.app's one update path,
// its server being in its own process): a plain shell, started by the app
// as it goes, which waits for it to end, installs the new bundle over the
// running one if there is one (that one kept aside), starts the app again
// and watches it: up to `appearWithin` seconds for its process to appear,
// then `firstAnswer` for it to answer the first time (on the server's port
// from its own process, or at the socket file when it doesn't listen on the
// port: no password yet), then `seconds` more. The app's process is the one
// `pid` names (Visor.app: the holder of its instance lock, so a second copy
// that loses the race and exits 0 is never taken for a crash). If the app's process goes (it quit, crashed, or launchd
// started another after a crash) or never answers, it's stopped, the
// previous bundle is put back, the rollback note says why
// (VisorServer+Rollback), and it's started again. A plain restart that
// doesn't come up is started once more. Once the new build has stayed up,
// the one it replaced is removed.
//
// `served` starts at 0 whatever the app was doing: an answer from the new
// process is what the watch waits for. (Until 0.72.1 it started at 1 for a
// server that didn't listen on its port, so "never answered" couldn't be
// said of it, and a build that ran and served nothing was kept.)
//
// Each command it runs on the system is a field, so a test runs the same
// script with stand-ins (//tests/visor_launch_agent_tests, on Linux).
//
// The app that goes is waited for by `kill -0`. On Linux a process that has
// exited but not been reaped (a container's first process may reap nothing)
// still answers it, so there /proc's `State: Z` says it has gone; a Mac has
// no /proc, and `kill -0` alone is asked there (the app's parent is launchd,
// which reaps it at once).

import Foundation
import VisorProtocol

public struct AppRelaunchWatch: Sendable {
    /// The app's process, waited for to end first.
    public var appPID: Int32
    /// The installed bundle: what's started.
    public var destination: String
    /// Where the running bundle is kept meanwhile; nil for a plain restart.
    public var backup: String?
    /// Shell: the new bundle put in place (the running one moved to
    /// `backup`); empty for a plain restart.
    public var install: String
    /// Shell: lifts the quarantine from a downloaded build the system
    /// accepts.
    public var accept: String
    /// Shell: starts the app (Visor.app: through its launchd agent, else
    /// `open -a`).
    public var start: String
    /// Shell: stops it, and keeps launchd from starting it again meanwhile.
    public var stop: String
    /// Shell: prints the app's process id while it runs, else nothing.
    public var pid: String
    /// Shell: succeeds when process `$p` answers.
    public var answers: String
    /// Where it's asked, for the log and the note ("on port 7433").
    public var answersWhere: String
    /// The rollback note.
    public var note: String
    public var newVersion: String
    public var oldVersion: String
    /// How long it must stay up; how long it has to answer first, once its
    /// process is up; and how long its process has to appear at all (a
    /// Mac's first run of a new build can wait on the system's checks
    /// before any of it runs).
    public var seconds: Int
    public var firstAnswer: Int
    public var appearWithin: Int
    /// How long the app that goes has to end before it's sent TERM, and
    /// then KILL (a quit held up by a modal, or a terminate never
    /// answered, would leave no server and the watch's lock held).
    public var endWithin: Int
    public var killAfter: Int
    /// How long it's given before the first look.
    public var settle: Int
    /// The lock that keeps one watch at a time (RelaunchWatchLock); nil:
    /// none (a test's).
    public var lock: String?
    /// The marker that has the app that's started show its window
    /// (Visor.app's `<bundle id>.present`, AppAgentJob.showsWindow): the
    /// time, written just before each start, when a window was open as the
    /// app went; nil: none, and the app keeps to the menu bar.
    public var present: String?

    public init(appPID: Int32, destination: String, backup: String?, install: String, accept: String = "", start: String, stop: String,
                pid: String, answers: String, answersWhere: String, note: String, newVersion: String, oldVersion: String,
                seconds: Int = 120, firstAnswer: Int = 120, appearWithin: Int = 600, endWithin: Int = 60, killAfter: Int = 10,
                settle: Int = 3, lock: String? = nil, present: String? = nil) {
        self.appPID = appPID
        self.destination = destination
        self.backup = backup
        self.install = install
        self.accept = accept
        self.start = start
        self.stop = stop
        self.pid = pid
        self.answers = answers
        self.answersWhere = answersWhere
        self.note = note
        self.newVersion = newVersion
        self.oldVersion = oldVersion
        self.seconds = seconds
        self.firstAnswer = firstAnswer
        self.appearWithin = appearWithin
        self.endWithin = endWithin
        self.killAfter = killAfter
        self.settle = settle
        self.lock = lock
        self.present = present
    }

    /// Shell: succeeds when the server's port answers `/api/hello` (any
    /// status: a refusal is an answer) and, where lsof shows who listens on
    /// it, that is process `$p`.
    public static func portAnswers(_ port: UInt16 = Envelope.defaultPort) -> String {
        "curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:\(port)/api/hello | grep -qv '^000$' "
            + "&& { l=$(lsof -nP -t -iTCP:\(port) -sTCP:LISTEN 2>/dev/null); [ -z \"$l\" ] || echo \"$l\" | grep -qx \"$p\"; }"
    }

    /// Shell: succeeds when the server's socket file answers `/api/hello`
    /// (the app's own server, with no password yet, serves there alone).
    /// The app that went has, so whoever answers there is the new one.
    public static func socketAnswers(_ path: String) -> String {
        "curl -s -o /dev/null -m 3 -w '%{http_code}' --unix-socket \(quoted(path)) http://localhost/api/hello | grep -qv '^000$'"
    }

    /// Shell: the process id the instance lock at `lock` names (its first
    /// line, InstanceLock's), while that process holds the lock; else
    /// nothing. The id stays in the file after its holder ends (the lock
    /// goes with the process, the file's words don't), and an id is reused:
    /// a live process by that id would be taken for the app, the fallback's
    /// open skipped ("launchd's copy came up after all") and a stranger
    /// watched, or stopped (NCH's check of #537). So the lock itself is
    /// asked (`lockHeld`), of a live process alone: as the app starts, the
    /// file still names the one that went, which has ended, and the probe
    /// never takes the lock from under the new one's take. Only a reused
    /// id has it take the lock, for a moment, which the app's take allows
    /// for (MacAppInstance: tried again for half a second).
    public static func lockHolder(_ lock: String) -> String {
        "h=$(head -1 \(quoted(lock)) 2>/dev/null | tr -dc 0-9); [ -n \"$h\" ] && kill -0 $h 2>/dev/null && \(lockHeld(lock)) && echo $h"
    }

    /// Shell: succeeds while a process holds the lock file `lock` (flock(2),
    /// as InstanceLock takes it): a try to take it at once fails with
    /// EX_TEMPFAIL (75); one that succeeds lets it go as it ends. A Mac's
    /// `/usr/bin/lockf` (`-k` keeps the file, `-n` makes none, `-s` quiet),
    /// else util-linux's `flock` (Linux's, the tests').
    public static func lockHeld(_ lock: String) -> String {
        "{ if [ -x /usr/bin/lockf ]; then /usr/bin/lockf -kns -t 0 \(quoted(lock)) true; else flock -n -E 75 \(quoted(lock)) true; fi; "
            + "[ $? = 75 ]; } 2>/dev/null"
    }

    /// The whole script. How long a build that runs and never serves leaves
    /// the Mac with no server before it's undone: the start through launchd
    /// (a registration, about two minutes at most), then `firstAnswer` (two
    /// minutes) once its process is up, then the undo: about five minutes.
    /// Only a build whose process never appears at all is waited for longer
    /// (`appearWithin`, ten minutes: the system's first checks of a build).
    public func script() -> String {
        """
        \(lock.map { RelaunchWatchLock.take($0) + "\n" } ?? "")w=0
        while kill -0 \(appPID) 2>/dev/null && ! { [ -r /proc/\(appPID)/status ] && grep -q '^State:.*Z' /proc/\(appPID)/status; }; do
          w=$((w+1))
          [ $w = \(endWithin * 5) ] && { echo "$(date): the app (process \(appPID)) didn't end within \(endWithin) s: sent TERM"; kill \(appPID) 2>/dev/null; }
          [ $w = \((endWithin + killAfter) * 5) ] && { echo "$(date): the app (process \(appPID)) didn't end after TERM: sent KILL"; kill -9 \(appPID) 2>/dev/null; }
          sleep 0.2
        done
        sleep 0.5
        \(install.isEmpty ? "" : install + "\n")\(accept.isEmpty ? "" : accept + "\n")installed=$(cat \(Self.quoted(destination))/Contents/MacOS/* 2>/dev/null | cksum)
        echo "$(date): starting \(newVersion)"
        \(starting)
        sleep \(settle)
        why=""; served=0; i=0; up=0; first=""; waited=0
        while :; do
          p=$(\(pid))
          if [ -z "$first" ]; then
            if [ -z "$p" ]; then
              waited=$((waited+1)); [ $waited -ge \(max(1, appearWithin / 2)) ] && { why="it never came up"; break; }
              sleep 2; continue
            fi
            first="$p"
          fi
          if [ -z "$p" ] || [ "$p" != "$first" ]; then why="it quit or crashed"; break; fi
          if \(answers); then served=1; fi
          if [ $served = 1 ]; then
            up=$((up+1)); [ $up -ge \(max(1, seconds / 2)) ] && break
          else
            i=$((i+1)); [ $i -ge \(max(1, firstAnswer / 2)) ] && break
          fi
          sleep 2
        done
        [ -z "$why" ] && [ $served = 0 ] && why="it never answered \(answersWhere)"
        if [ -n "$why" ]; then
        \(undo)
        else
          echo "$(date): \(newVersion) stayed up"
        \(removeReplaced)
        fi
        """
    }

    /// The new build undone: stopped, the previous bundle back, the note
    /// written and the app started; or, with nothing to put back, started
    /// once more. The bundle in place is replaced only when this watch's
    /// own copy of the previous one is there, whole, and the bundle in
    /// place is still the one it installed (another watch, or a person, may
    /// have put another there since): otherwise it's left as it is, and
    /// said.
    private var undo: String {
        guard let backup else {
            return """
            echo "$(date): \(newVersion) did not come up ($why); starting it once more"
            \(stop)
            \(starting)
            """
        }
        let words = "Visor Server \(newVersion) did not stay up after the update ($why), so \(oldVersion) was put back."
        return """
        \(stop)
        if [ -d \(Self.quoted(backup)) ] && [ -d \(Self.quoted(backup))/Contents/MacOS ] \\
           && [ "$(cat \(Self.quoted(destination))/Contents/MacOS/* 2>/dev/null | cksum)" = "$installed" ]; then
          rm -rf \(Self.quoted(destination)) && mv \(Self.quoted(backup)) \(Self.quoted(destination))
          \(removeFolders(of: backup))
          printf '%s\\n' "\(words)" > \(Self.quoted(note))
          echo "$(date): rolled back to \(oldVersion): $why"
        else
          echo "$(date): \(newVersion) did not stay up ($why), but \(destination) was left as it is: this watch's copy of \(oldVersion) is gone, or the bundle there isn't the one it installed"
        fi
        \(starting)
        """
    }

    /// Shell: the app started, its window asked for first when one was open.
    private var starting: String {
        guard let present else { return start }
        return "date +%s > \(Self.quoted(present))\n\(start)"
    }

    /// The build it replaced, gone once the new one has stayed up (no
    /// backups left on the computer; Logan, 7 Nov).
    private var removeReplaced: String {
        guard let backup else { return "" }
        return "rm -rf \(Self.quoted(backup)) && { \(removeFolders(of: backup)); }; echo \"$(date): the build it replaced is removed\""
    }

    /// Shell: the backup's folders, once empty (`Previous/<token>`, then
    /// `Previous`).
    private func removeFolders(of backup: String) -> String {
        let token = (backup as NSString).deletingLastPathComponent
        return "rmdir \(Self.quoted(token)) 2>/dev/null; rmdir \(Self.quoted((token as NSString).deletingLastPathComponent)) 2>/dev/null"
    }

    /// A path as one shell word.
    public static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

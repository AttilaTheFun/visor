// Unused from 0.72.1, when the server moved into the app and the app's own
// relaunch (AppRelauncher, AppRelaunchWatch) became the one update path:
// kept one release, for `Visor --server` (MacServerAgent), which a build
// before 0.72.1 starts while updating to it. Remove in the release after.
//
// The server agent's restart and its watch (ServerAgentRestart): a plain
// shell, started detached by the server as it goes, which waits for it to
// end, installs the new bundle over the running one if there is one (that
// one kept aside, the job's plist inside each), starts the job again, and
// watches it as AppRelauncher watches the app it reopens: up to
// `firstAnswer` seconds for it to answer `/api/hello` on the server's port
// the first time, from the job's own process, then `seconds` more. If the
// job's process goes (it quit, crashed, or launchd started another) or
// never answers, the job is stopped, the previous bundle is put back, the
// rollback note says why (VisorServer+Rollback), and the job is
// started again. A plain restart that doesn't come up is started once more.
// Once the new build has stayed up, the one it replaced is removed.
//
// Each command it runs on launchd is a field, so a test runs the same
// script with stand-ins.

import Foundation
import VisorProtocol
import VisorServer

public struct ServerAgentWatch: Sendable {
    /// The server's process, waited for to end first.
    public var serverPID: Int32
    /// The installed bundle: what the job runs.
    public var destination: String
    /// The new bundle, put where `destination` is first; nil for a plain
    /// restart.
    public var source: String?
    /// Where the running bundle is kept meanwhile.
    public var backup: String?
    /// A plist put back with the previous bundle, and the one it replaced
    /// (nil: none; the server agent's plist is in its bundle, which comes
    /// back with it).
    public var plist: String
    public var previousPlist: String?
    /// Shell: starts the job once the server has gone.
    public var start: String
    /// Shell: starts the job again (after a rollback).
    public var reload: String
    /// Shell: stops the job.
    public var stop: String
    /// Shell: prints the job's process id while it runs, else nothing.
    public var pid: String
    /// Shell: succeeds when process `$p` answers on the server's port.
    public var answers: String
    /// Shell: lifts the quarantine from a downloaded build the system
    /// accepts (AppRelauncher's).
    public var accept: String
    /// The rollback note.
    public var note: String
    public var newVersion: String
    public var oldVersion: String
    public var port: UInt16
    /// How long it must stay up, and how long it has to answer first.
    public var seconds: Int
    public var firstAnswer: Int
    /// How long it's given before the first look.
    public var settle: Int
    /// The lock that keeps one watch at a time (RelaunchWatchLock); nil:
    /// none (a test's).
    public var lock: String?
    /// The bundle's executable, inside it (`Contents/MacOS/Visor`): its
    /// checksum says whether the bundle in place is still the one this
    /// watch installed, before an undo touches it.
    public var bundleExecutable: String

    public init(serverPID: Int32, destination: String, source: String?, backup: String?, plist: String, previousPlist: String?,
                start: String, reload: String, stop: String, pid: String, answers: String, accept: String = "", note: String,
                newVersion: String, oldVersion: String, port: UInt16 = Envelope.defaultPort, seconds: Int = 120, firstAnswer: Int = 600,
                settle: Int = 3, lock: String? = nil, bundleExecutable: String = "Contents/MacOS/Visor") {
        self.serverPID = serverPID
        self.destination = destination
        self.source = source
        self.backup = backup
        self.plist = plist
        self.previousPlist = previousPlist
        self.start = start
        self.reload = reload
        self.stop = stop
        self.pid = pid
        self.answers = answers
        self.accept = accept
        self.note = note
        self.newVersion = newVersion
        self.oldVersion = oldVersion
        self.port = port
        self.seconds = seconds
        self.firstAnswer = firstAnswer
        self.settle = settle
        self.lock = lock
        self.bundleExecutable = bundleExecutable
    }

    /// The watcher for `job` on this user's launchd. A plain restart (no
    /// `source`) is started with `kickstart -k`, or registered again if
    /// launchd no longer has it. After an update to another build, and
    /// after a rollback to the one before, it's registered afresh from the
    /// bundle in place (`<executable> server-agent register`: unregistered,
    /// booted out, then registered, ServerAgentService.reregister), as SMAppService's
    /// launch constraint is the bundle it was registered from, and launchd
    /// won't spawn the job from another put in its place. Stopped with a
    /// KILL, which its KeepAlive would answer only after the bundle is back.
    public static func launchd(job: LaunchAgentJob, serverPID: Int32, destination: String, executable: String, source: String?,
                               backup: String?, note: String, newVersion: String, oldVersion: String, lock: String? = nil,
                               port: UInt16 = Envelope.defaultPort) -> ServerAgentWatch {
        let target = "gui/$(id -u)/\(job.label)"
        let register = registerCommand(destination: destination, executable: executable)
        let start = source == nil ? "launchctl kickstart -k \(target) 2>/dev/null || \(register)" : register
        return ServerAgentWatch(serverPID: serverPID, destination: destination, source: source, backup: backup, plist: job.plistPath,
                                previousPlist: nil, start: start, reload: register,
                                stop: "launchctl kill SIGKILL \(target) 2>/dev/null; sleep 0.5",
                                pid: "launchctl print \(target) 2>/dev/null | awk '$1==\"pid\" && $2==\"=\" {print $3; exit}'",
                                answers: answers(port: port),
                                accept: "spctl --assess --type execute \(quoted(destination)) >/dev/null 2>&1 && xattr -rd com.apple.quarantine \(quoted(destination)) 2>/dev/null",
                                note: note, newVersion: newVersion, oldVersion: oldVersion, port: port, lock: lock,
                                bundleExecutable: "Contents/MacOS/" + executable)
    }

    /// Shell: the agent registered afresh from the bundle at `destination`
    /// (`<its executable> server-agent register`).
    public static func registerCommand(destination: String, executable: String) -> String {
        quoted((destination as NSString).appendingPathComponent("Contents/MacOS/" + executable)) + " \(ServerAgentJob.command) register"
    }

    /// Shell: succeeds when the server's port answers `/api/hello` (any
    /// status: a refusal is an answer) and, where lsof shows who listens on
    /// it, that is process `$p`.
    public static func answers(port: UInt16) -> String {
        "curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:\(port)/api/hello | grep -qv '^000$' "
            + "&& { l=$(lsof -nP -t -iTCP:\(port) -sTCP:LISTEN 2>/dev/null); [ -z \"$l\" ] || echo \"$l\" | grep -qx \"$p\"; }"
    }

    /// The whole script.
    public func script() -> String {
        """
        \(lock.map { RelaunchWatchLock.take($0) + "\n" } ?? "")while kill -0 \(serverPID) 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        \(install)\(accept)
        installed=$(cksum < \(Self.quoted(installedExecutable)) 2>/dev/null)
        echo "$(date): the server agent started again (\(newVersion))"
        \(start)
        sleep \(settle)
        why=""; served=0; i=0; up=0; first=""
        while :; do
          p=$(\(pid))
          [ -z "$first" ] && first="$p"
          if [ -z "$p" ] || [ "$p" != "$first" ]; then why="it quit or crashed"; break; fi
          if \(answers); then served=1; fi
          if [ $served = 1 ]; then
            up=$((up+1)); [ $up -ge \(max(1, seconds / 2)) ] && break
          else
            i=$((i+1)); [ $i -ge \(max(1, firstAnswer / 2)) ] && break
          fi
          sleep 2
        done
        [ -z "$why" ] && [ $served = 0 ] && why="it never answered on port \(port)"
        if [ -n "$why" ]; then
        \(undo)
        else
          echo "$(date): \(newVersion) stayed up"
        \(removeReplaced)
        fi
        """
    }

    /// The previous plist put back, if there is one.
    private var putPlistBack: String {
        previousPlist.map { "[ -f \(Self.quoted($0)) ] && mv -f \(Self.quoted($0)) \(Self.quoted(plist))" } ?? ":"
    }

    /// The new bundle in the running one's place, that one kept aside; if
    /// that can't be done, all put back and the job started as it was.
    private var install: String {
        guard let source, let backup else { return "" }
        let restart = "\(putPlistBack); \(reload)"
        return """
        mkdir -p \(Self.quoted((backup as NSString).deletingLastPathComponent)) && rm -rf \(Self.quoted(backup))
        if ! mv \(Self.quoted(destination)) \(Self.quoted(backup)); then echo "$(date): \(destination) couldn't be moved aside"; \(restart); exit 1; fi
        if ! cp -R \(Self.quoted(source)) \(Self.quoted(destination)); then
          echo "$(date): \(source) couldn't be copied in"; rm -rf \(Self.quoted(destination)); mv \(Self.quoted(backup)) \(Self.quoted(destination)); \(restart); exit 1
        fi

        """
    }

    /// The executable of the bundle in place, by its full path.
    private var installedExecutable: String { (destination as NSString).appendingPathComponent(bundleExecutable) }

    /// The new build undone: the job stopped, the previous bundle and plist
    /// back, the note written and the job started; or, with nothing to put
    /// back, started once more. The bundle in place is replaced only when
    /// this watch's own copy of the previous one is there, whole, and the
    /// bundle in place is still the one it installed (another watch, or a
    /// person, may have put another there since): otherwise it's left as
    /// it is, and said.
    private var undo: String {
        guard let backup else {
            return """
            echo "$(date): \(newVersion) did not come up ($why); starting it once more"
            \(previousPlist == nil ? "" : putPlistBack + "\n")\(reload)
            """
        }
        let words = "Visor Server \(newVersion) did not stay up after the update ($why), so \(oldVersion) was put back."
        return """
        \(stop)
        if [ -d \(Self.quoted(backup)) ] && [ -f \(Self.quoted((backup as NSString).appendingPathComponent(bundleExecutable))) ] \\
           && [ -n "$installed" ] && [ "$(cksum < \(Self.quoted(installedExecutable)) 2>/dev/null)" = "$installed" ]; then
          rm -rf \(Self.quoted(destination)) && mv \(Self.quoted(backup)) \(Self.quoted(destination))
          \(removeFolders(of: backup))
          printf '%s\\n' "\(words)" > \(Self.quoted(note))
          echo "$(date): rolled back to \(oldVersion): $why"
        else
          echo "$(date): \(newVersion) did not stay up ($why), but \(destination) was left as it is: this watch's copy of \(oldVersion) is gone, or the bundle there isn't the one it installed"
        fi
        \(putPlistBack)
        \(reload)
        """
    }

    /// The build it replaced, and the plist, gone once the new one has
    /// stayed up (no backups left on the computer; Logan, 7 Nov).
    private var removeReplaced: String {
        var lines: [String] = []
        if let backup {
            lines.append("rm -rf \(Self.quoted(backup)) && { \(removeFolders(of: backup)); }; echo \"$(date): the build it replaced is removed\"")
        }
        if let previousPlist { lines.append("rm -f \(Self.quoted(previousPlist))") }
        return lines.joined(separator: "\n")
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

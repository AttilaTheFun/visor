import AppKit
import Foundation
import VisorProtocol
import VisorServer

/// How the menu bar app replaces itself: a plain shell, started now, waits
/// for this process to go, installs the new bundle over this one if there
/// is one, and starts the app again. It is reparented to launchd when the
/// app exits, so nothing it does depends on the app still being there.
///
/// An update is undone when the new build does not stay up: the bundle
/// that was running is kept aside, and for `watch` seconds after starting
/// the new one the shell checks it is still running and that it answers
/// (on its port from its own process, or at its socket file while it has
/// no password to listen with). If it quits, crashes or never answers, the
/// shell ends it, puts the previous bundle back, writes why to the rollback
/// note (VisorServer+Rollback.swift) and starts the previous build. A plain
/// restart that does not come up is started once more. The script is
/// AppRelaunchWatch's, tested on Linux.
///
/// With an `agent` (Visor.app from 0.72.1: its own launchd agent, which
/// starts it at login and again after a crash), the app is started through
/// launchd, so the process that comes back is the agent's and a crash of it
/// is answered: `<executable> app-agent start`, which registers the agent
/// afresh from the bundle in place (its launch constraint is the bundle it
/// was registered from, so after an update launchd would start nothing
/// until it is), which starts it. This process exits 0 first, which
/// launchd's KeepAlive leaves alone: the watcher, not launchd, brings it
/// back, and the two never race. Not wanted, or launchd not starting it,
/// and it is opened as before (`open -a`, its `--without-agent` telling it
/// not to hand itself to launchd again). Either way the app comes back with
/// its window if one was open as it went, and in the menu bar alone if none
/// was (the agent's `presentMarker`, written just before each start).
public struct AppRelauncher: ServerLifecycle {
    /// How long a new build has to stay up before it is trusted.
    public static let watch = 120
    /// How long a new build has to answer the first time while it runs.
    public static let firstAnswer = 600

    /// Where the relauncher's shell writes: Visor's logs' folder
    /// (VisorFolders.logs, on the Visor volume once it's there).
    public let logPath: String

    /// The app's own launchd agent, which starts it.
    public struct Agent: Sendable {
        /// Its launchd label (`com.LoganShire.Visor.app`).
        public var label: String
        /// The app's command that starts it from the bundle in place
        /// (`app-agent start`): exits 0 once launchd runs the app.
        public var command: [String]
        /// The marker that has the app launchd starts show its window,
        /// written when one was open as the app went (an update then gives
        /// back the window it found).
        public var presentMarker: String?

        public init(label: String, command: [String], presentMarker: String? = nil) {
            self.label = label
            self.command = command
            self.presentMarker = presentMarker
        }
    }

    /// The app's agent, if it has one; nil: opened with `open -a` alone.
    public let agent: Agent?

    /// The argument of an open that comes after launchd didn't start the
    /// app as its agent.
    public static let withoutAgent = "--without-agent"

    public init(logPath: String = "/tmp/visor-relaunch.log", agent: Agent? = nil) {
        self.logPath = logPath
        self.agent = agent
    }

    @MainActor
    public func relaunch(installing build: String?, carrying sessions: String) -> String? {
        var destination = Bundle.main.bundlePath
        var install = ""
        // What to put back if the new build does not stay up.
        var backup: String?
        var newVersion = Self.version(of: Bundle.main)
        if let build, !build.isEmpty {
            let source = (build as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: source + "/Contents/MacOS") else {
                return "No app bundle at \(source)"
            }
            let incoming = Bundle(path: source)
            let identifier = incoming?.bundleIdentifier ?? ""
            let replaces = incoming?.object(forInfoDictionaryKey: "VisorReplaces") as? [String] ?? []
            newVersion = incoming.map(Self.version(of:)) ?? newVersion
            if identifier == Bundle.main.bundleIdentifier {
                if source != destination {
                    // In a folder of this watch's own (RelaunchWatchLock).
                    let kept = RelaunchWatchLock.backup(for: destination)
                    backup = kept
                    // The running bundle is moved aside, not removed: it is
                    // what comes back if the new one fails.
                    install = """
                    mkdir -p \(Self.quoted((kept as NSString).deletingLastPathComponent)) && rm -rf \(Self.quoted(kept))
                    mv \(Self.quoted(destination)) \(Self.quoted(kept)) || exit 1
                    cp -R \(Self.quoted(source)) \(Self.quoted(destination)) || { rm -rf \(Self.quoted(destination)); mv \(Self.quoted(kept)) \(Self.quoted(destination)); open -a \(Self.quoted(destination)) --args --resume-sessions \(Self.quoted(sessions)); exit 1; }

                    """
                }
            } else if let current = Bundle.main.bundleIdentifier, replaces.contains(current) {
                // The app that takes over from this one: installed beside it
                // under its own name, this one removed, and anything that
                // opened this one at login (a LaunchAgent) pointed at it.
                let replacement = ((destination as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent((source as NSString).lastPathComponent)
                let agents = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
                install = """
                rm -rf \(Self.quoted(replacement)) && cp -R \(Self.quoted(source)) \(Self.quoted(replacement)) || exit 1
                rm -rf \(Self.quoted(destination))
                for f in \(Self.quoted(agents))/*.plist; do
                  grep -qF \(Self.quoted(destination)) "$f" 2>/dev/null && sed -i '' "s#\(destination)#\(replacement)#g" "$f"
                done

                """
                destination = replacement
            } else {
                return "\(source) is \(identifier.isEmpty ? "not an app" : identifier), not \(Bundle.main.bundleIdentifier ?? "this app")"
            }
        }
        // With an agent, the open is the fallback once launchd didn't start
        // the app: it says so (`--without-agent`), and the app runs where it
        // is rather than ask launchd again.
        let open = "open -a \(Self.quoted(destination)) --args --resume-sessions \(Self.quoted(sessions))"
            + (agent == nil ? "" : " \(Self.withoutAgent)")
        // A build that came as a download (a Taildrop, a browser) carries
        // the quarantine through its bundle, and its first open waits on
        // the system's "downloaded from the Internet" question on the Mac's
        // screen, the server not running meanwhile: lifted, once the system
        // accepts the build (notarized, Developer ID).
        let accept = "spctl --assess --type execute \(Self.quoted(destination)) >/dev/null 2>&1 && xattr -rd com.apple.quarantine \(Self.quoted(destination)) 2>/dev/null"
        let executable = (destination as NSString).appendingPathComponent(
            "Contents/MacOS/" + Self.executableName(of: build.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }))
        let serving = VisorServer.shared.listening
        // A window of the app's open as it goes: shown again once it's back.
        let windowOpen = NSApplication.shared.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        // One watch at a time (RelaunchWatchLock).
        let watch = AppRelaunchWatch(appPID: ProcessInfo.processInfo.processIdentifier, destination: destination, backup: backup,
                                     install: install, accept: accept, start: start(executable: executable, open: open),
                                     stop: stop(executable: executable), pid: pid(executable: executable),
                                     answers: serving ? AppRelaunchWatch.portAnswers() : AppRelaunchWatch.socketAnswers(VisorServer.socketPath),
                                     answersWhere: serving ? "on port \(Envelope.defaultPort)" : "at its socket file",
                                     note: VisorServer.rollbackNoteURL.path, newVersion: newVersion, oldVersion: Self.version(of: Bundle.main),
                                     lock: RelaunchWatchLock.url.path, present: windowOpen ? agent?.presentMarker : nil)
        let script = watch.script()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        // Somewhere to look when a relaunch does not come back.
        try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            process.standardOutput = log
            process.standardError = log
        }
        do { try process.run() } catch { return "Could not start the relauncher: \(error.localizedDescription)" }
        // Held at once, before its shell takes it: a restart asked of the
        // next server meanwhile is refused.
        try? Data("\(process.processIdentifier) \(Int(Date().timeIntervalSince1970))\n".utf8).write(to: RelaunchWatchLock.url, options: .atomic)
        return nil
    }

    /// Shell: the app started, through its agent when it has one (`open -a`
    /// when that doesn't start it), else opened.
    func start(executable: String, open: String) -> String {
        guard let agent else { return open }
        let command = ([executable] + agent.command).map(Self.quoted).joined(separator: " ")
        return "\(command) || { echo \"$(date): launchd didn't start it: opened instead\"; \(open); }"
    }

    /// Shell: the app stopped: its agent out of launchd first (so KeepAlive
    /// starts nothing while the bundle is put back), then whatever runs
    /// from the bundle as the app.
    func stop(executable: String) -> String {
        let bootout = agent.map { "launchctl bootout gui/$(id -u)/\($0.label) 2>/dev/null; " } ?? ""
        return "\(bootout)for q in $(\(appProcesses(executable))); do kill $q 2>/dev/null; done; sleep 2; "
            + "for q in $(\(appProcesses(executable))); do kill -9 $q 2>/dev/null; done"
    }

    /// Shell: the app's process id: the agent's job's, as launchd says,
    /// else the first process of the bundle's that is the app.
    func pid(executable: String) -> String {
        let own = "\(appProcesses(executable)) | head -1"
        guard let agent else { return own }
        let job = "launchctl print gui/$(id -u)/\(agent.label) 2>/dev/null | awk '$1==\"pid\" && $2==\"=\" {print $3; exit}'"
        return "j=$(\(job)); if [ -n \"$j\" ]; then echo \"$j\"; else \(own); fi"
    }

    /// Shell: the processes running `executable` as the app: by itself or
    /// with its launch's arguments (`--resume-sessions`), not as one of its
    /// agents (`--server`, `--agent-proxy`) or commands (a word), nor any
    /// process that merely names it (this watcher's own shell).
    func appProcesses(_ executable: String) -> String {
        let exe = Self.quoted(executable)
        return "pgrep -f \(exe) | while read q; do case \"$(ps -o args= -p $q 2>/dev/null)\" in "
            + "\(exe)' --server'*|\(exe)' --agent-proxy'*) ;; \(exe)|\(exe)' -'*) echo $q;; esac; done"
    }

    /// The executable's name in the bundle at `path` (the running one's
    /// when nil).
    static func executableName(of path: String?) -> String {
        let info = path.flatMap { Bundle(path: $0)?.infoDictionary } ?? Bundle.main.infoDictionary
        return info?["CFBundleExecutable"] as? String ?? Bundle.main.executableURL?.lastPathComponent ?? ""
    }

    /// "0.38.7" ("0.31 (2)" before 0.38), as a bundle names its version.
    static func version(of bundle: Bundle) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return VersionTitle.of(version: short, build: build)
    }

    @MainActor
    public func terminate() {
        NSApplication.shared.terminate(nil)
    }

    /// A path as one shell word.
    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

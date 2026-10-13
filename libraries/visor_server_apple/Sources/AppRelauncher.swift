import AppKit
import Foundation
import VisorProtocol
import VisorServer

/// How the menu bar app replaces itself: a plain shell, started now, waits
/// for this process to go, installs the new bundle over this one if there
/// is one, and opens the app again. It is reparented to launchd when the
/// app exits, so nothing it does depends on the app still being there.
///
/// An update is undone when the new build does not stay up: the bundle
/// that was running is kept aside, and for `watch` seconds after opening
/// the new one the shell checks it is still running (and, if this one was
/// serving, that it answers on its port). If it quits, crashes or never
/// answers, the shell ends it, puts the previous bundle back, writes why
/// to the rollback note (VisorServer+Rollback.swift) and opens the previous
/// build, carrying on the same sessions. A plain restart that does not come
/// up is opened once more.
public struct AppRelauncher: ServerLifecycle {
    /// How long a new build has to stay up before it is trusted.
    public static let watch = 120

    public init() {}

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
                    let kept = VisorServer.rollbackNoteURL.deletingLastPathComponent()
                        .appendingPathComponent("Previous", isDirectory: true)
                        .appendingPathComponent((destination as NSString).lastPathComponent, isDirectory: true).path
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
        let open = "open -a \(Self.quoted(destination)) --args --resume-sessions \(Self.quoted(sessions))"
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        \(install)\(open)
        \(Self.watching(destination: destination, backup: backup, serving: VisorServer.shared.listening,
                        newVersion: newVersion, oldVersion: Self.version(of: Bundle.main), open: open))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        // Somewhere to look when a relaunch does not come back.
        let logPath = "/tmp/visor-relaunch.log"
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            process.standardOutput = log
            process.standardError = log
        }
        do { try process.run() } catch { return "Could not start the relauncher: \(error.localizedDescription)" }
        return nil
    }

    /// The shell that watches the opened build for `watch` seconds, and
    /// undoes the update (or, with nothing to undo, opens it once more) if
    /// it does not stay up.
    @MainActor
    static func watching(destination: String, backup: String?, serving: Bool, newVersion: String, oldVersion: String,
                         open: String, seconds: Int = watch) -> String {
        let running = "pgrep -f \(quoted(destination + "/Contents/MacOS/")) >/dev/null"
        let answers = "curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:\(Envelope.defaultPort)/api/hello | grep -qv '^000$'"
        let undo: String
        if let backup {
            let note = "Visor Server \(newVersion) did not stay up after the update ($why), so \(oldVersion) was put back."
            undo = """
            pkill -f \(quoted(destination + "/Contents/MacOS/")); sleep 2; pkill -9 -f \(quoted(destination + "/Contents/MacOS/"))
            if [ -d \(quoted(backup)) ]; then
              rm -rf \(quoted(destination)) && mv \(quoted(backup)) \(quoted(destination))
              printf '%s\\n' "\(note)" > \(quoted(VisorServer.rollbackNoteURL.path))
              echo "$(date): rolled back to \(oldVersion): $why"
            fi
            \(open)
            """
        } else {
            undo = """
            echo "$(date): \(newVersion) did not come up ($why); opening it once more"
            \(open)
            """
        }
        return """
        sleep 3
        why=""; served=\(serving ? 0 : 1); i=0
        while [ $i -lt \(max(1, seconds / 2)) ]; do
          if ! \(running); then why="it quit or crashed"; break; fi
          \(answers) && served=1
          sleep 2; i=$((i+1))
        done
        [ -z "$why" ] && [ $served = 0 ] && why="it never answered on port \(Envelope.defaultPort)"
        if [ -n "$why" ]; then
        \(undo)
        else
          echo "$(date): \(newVersion) stayed up"
        fi
        """
    }

    /// "0.31 (2)", as a bundle names its version.
    static func version(of bundle: Bundle) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    @MainActor
    public func terminate() {
        NSApplication.shared.terminate(nil)
    }

    /// A path as one shell word.
    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

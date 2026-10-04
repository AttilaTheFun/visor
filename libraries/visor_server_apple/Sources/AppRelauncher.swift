import AppKit
import Foundation
import VisorServer

/// How the menu bar app replaces itself: a plain shell, started now, waits
/// for this process to go, installs the new bundle over this one if there
/// is one, and opens the app again. It is reparented to launchd when the
/// app exits, so nothing it does depends on the app still being there.
public struct AppRelauncher: ServerLifecycle {
    public init() {}

    @MainActor
    public func relaunch(installing build: String?, carrying sessions: String) -> String? {
        var destination = Bundle.main.bundlePath
        var install = ""
        if let build, !build.isEmpty {
            let source = (build as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: source + "/Contents/MacOS") else {
                return "No app bundle at \(source)"
            }
            let incoming = Bundle(path: source)
            let identifier = incoming?.bundleIdentifier ?? ""
            let replaces = incoming?.object(forInfoDictionaryKey: "VisorReplaces") as? [String] ?? []
            if identifier == Bundle.main.bundleIdentifier {
                if source != destination {
                    install = "rm -rf \(Self.quoted(destination)) && cp -R \(Self.quoted(source)) \(Self.quoted(destination)) || exit 1\n"
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
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        \(install)open -a \(Self.quoted(destination)) --args --resume-sessions \(Self.quoted(sessions))
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

    @MainActor
    public func terminate() {
        NSApplication.shared.terminate(nil)
    }

    /// A path as one shell word.
    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

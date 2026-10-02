// Ending: a relaunch into another build, the agents stopped before a
// quit.

import AppKit
import ClaudeTranscript
import MessageCache
import Foundation
import Network
import VisorProtocol

extension VisorServer {
    /// Restarts the app, optionally installing `bundle` over ourselves
    /// first, and asks the new one to carry on `carrying`. Returns what went
    /// wrong, or nil — on success this process is on its way out.
    ///
    /// The relauncher is a plain shell that waits for our pid to go away: it
    /// is reparented to launchd when we exit, so nothing it does depends on
    /// us still being here.
    @discardableResult
    public func relaunch(installing bundle: String?, carrying: [String]) -> String? {
        var destination = Bundle.main.bundlePath
        var install = ""
        if let bundle, !bundle.isEmpty {
            let source = (bundle as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: source + "/Contents/MacOS") else {
                return "No app bundle at \(source)"
            }
            let incoming = Bundle(path: source)
            let identifier = incoming?.bundleIdentifier ?? ""
            let replaces = incoming?.object(forInfoDictionaryKey: "VisorReplaces") as? [String] ?? []
            if identifier == Bundle.main.bundleIdentifier {
                if source != destination {
                    install = "rm -rf \(Self.shellQuoted(destination)) && cp -R \(Self.shellQuoted(source)) \(Self.shellQuoted(destination)) || exit 1\n"
                }
            } else if let current = Bundle.main.bundleIdentifier, replaces.contains(current) {
                // The app that takes over from this one: installed beside it
                // under its own name, this one removed, and anything that
                // opened this one at login (a LaunchAgent) pointed at it.
                let replacement = ((destination as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent((source as NSString).lastPathComponent)
                let agents = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
                install = """
                rm -rf \(Self.shellQuoted(replacement)) && cp -R \(Self.shellQuoted(source)) \(Self.shellQuoted(replacement)) || exit 1
                rm -rf \(Self.shellQuoted(destination))
                for f in \(Self.shellQuoted(agents))/*.plist; do
                  grep -qF \(Self.shellQuoted(destination)) "$f" 2>/dev/null && sed -i '' "s#\(destination)#\(replacement)#g" "$f"
                done

                """
                destination = replacement
            } else {
                return "\(source) is \(identifier.isEmpty ? "not an app" : identifier), not \(Bundle.main.bundleIdentifier ?? "this app")"
            }
        }
        // The sessions that are mid-turn are written down as such: the flag
        // is what the next launch reads to know a reply is owed.
        for record in sessions where record.info.busy { record.interrupted = true }
        saveArchive()
        // Empty means the default: everything that was running. A caller
        // that names sessions gets exactly those.
        let list = carrying.joined(separator: ",")
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        \(install)open -a \(Self.shellQuoted(destination)) --args --resume-sessions \(Self.shellQuoted(list))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        // Somewhere to look when a relaunch does not come back.
        let logPath = "/tmp/visor-relaunch.log"
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
        }
        do { try p.run() } catch { return "Could not start the relauncher: \(error.localizedDescription)" }
        // Once the answer to whoever asked has gone out.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            quit()
        }
        return nil
    }

    /// A path as one shell word.
    static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Ends every session (the app is quitting). What was running is
    /// written down as running, so the next launch can carry it on: this is
    /// the record of the shutdown, however the app was quit.
    public func endAll() async {
        for record in sessions where record.info.busy { record.interrupted = true }
        saveArchive()
        // What the agents say as they go is not heard: the record of the
        // shutdown is the one just written.
        for record in sessions { record.stopListening() }
        // Waited for, not merely asked: an agent that outlives the app
        // runs on with nobody at the other end of its pipes. All at once:
        // each has its own few seconds to go.
        let ending = sessions.map { record in Task { await record.process.end(within: .seconds(4)) } }
        for task in ending { await task.value }
        agentsEnded = true
    }

    /// Ends the agents, then the app. The way to quit from the app's own
    /// code: the agents are gone before the app is asked to terminate, so
    /// it has nothing to wait for then.
    public func quit() {
        Task {
            await endAll()
            NSApplication.shared.terminate(nil)
        }
    }
}

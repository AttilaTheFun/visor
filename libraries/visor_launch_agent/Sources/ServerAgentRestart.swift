// How the server agent (`Visor --server`, ServerAgentJob) is replaced and
// ended: its ServerLifecycle. A restart, or an update (`POST /api/restart
// {path}`), rewrites the job's plist to the new executable and version and
// starts a detached watcher (ServerAgentWatch), which, once this process
// has gone, puts the new bundle in place, starts the job again (`launchctl
// kickstart -k`, or a fresh bootstrap when the plist changed) and watches it
// for two minutes, putting the previous build back if it doesn't stay up.
// The agents' hosts outlive it, as an in-place relaunch leaves them
// (VisorServer.relaunch), and the new server picks them up.
//
// Ending is exiting 0, which launchd's KeepAlive (after a failure only)
// leaves ended: a stop asked for (`/api/quit`) stays stopped, and a restart
// is the watcher's to start.
//
// Every session that was running is carried on (launchd starts the job with
// no list to narrow it: VisorServer's default, "all").

import Foundation
import VisorProtocol
import VisorServer
import VisorServerPOSIX

public struct ServerAgentRestart: ServerLifecycle {
    public let job: LaunchAgentJob

    public init(job: LaunchAgentJob) {
        self.job = job
    }

    @MainActor
    public func relaunch(installing build: String?, carrying sessions: String) -> String? {
        let destination = Bundle.main.bundlePath
        guard let running = Self.info(of: destination), let identifier = running["CFBundleIdentifier"] as? String else {
            return "\(destination) isn't an app bundle"
        }
        let oldVersion = Self.version(running)
        var newVersion = oldVersion
        var executableName = running["CFBundleExecutable"] as? String ?? Bundle.main.executableURL?.lastPathComponent ?? ""
        var source: String?
        var backup: String?
        if let build, !build.isEmpty {
            let path = ((build as NSString).expandingTildeInPath as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: path + "/Contents/MacOS"), let incoming = Self.info(of: path) else {
                return "No app bundle at \(path)"
            }
            let theirs = incoming["CFBundleIdentifier"] as? String ?? ""
            guard theirs == identifier else { return "\(path) is \(theirs.isEmpty ? "not an app" : theirs), not \(identifier)" }
            newVersion = Self.version(incoming)
            executableName = incoming["CFBundleExecutable"] as? String ?? executableName
            if path != (destination as NSString).standardizingPath {
                source = path
                // The running bundle is moved aside, not removed: it is what
                // comes back if the new one fails (AppRelauncher's place).
                backup = VisorServer.rollbackNoteURL.deletingLastPathComponent()
                    .appendingPathComponent("Previous", isDirectory: true)
                    .appendingPathComponent((destination as NSString).lastPathComponent, isDirectory: true).path
            }
        }
        let executable = (destination as NSString).appendingPathComponent("Contents/MacOS/" + executableName)
        if let problem = LaunchAgentJob.installProblem(executable) { return "The server agent can't restart itself: \(problem)" }
        // The plist to the new executable and version; the one it replaces
        // beside it, for the watcher to put back.
        let previous = FileManager.default.contents(atPath: job.plistPath)
        let previousPath = job.plistPath + ".previous"
        let data: Data
        do { data = try job.plistData(executable: executable, version: newVersion, settings: nil) } catch {
            return "The server agent's plist couldn't be made: \(error)"
        }
        let reloads = previous != data
        if reloads {
            do {
                if let previous { try previous.write(to: URL(fileURLWithPath: previousPath), options: .atomic) }
                try data.write(to: URL(fileURLWithPath: job.plistPath), options: .atomic)
            } catch {
                return "The server agent's plist couldn't be written: \(error)"
            }
        }
        let watch = ServerAgentWatch.launchd(job: job, serverPID: ProcessInfo.processInfo.processIdentifier, destination: destination,
                                             source: source, backup: backup, previousPlist: reloads && previous != nil ? previousPath : nil,
                                             reloads: reloads, note: VisorServer.rollbackNoteURL.path, newVersion: newVersion,
                                             oldVersion: oldVersion)
        do {
            _ = try POSIXDaemon.start("/bin/sh", ["-c", watch.script()], log: job.log)
        } catch {
            if reloads, let previous { try? previous.write(to: URL(fileURLWithPath: job.plistPath), options: .atomic) }
            return "Could not start the server agent's watcher: \(error.localizedDescription)"
        }
        if !sessions.isEmpty {
            ServerPlatform.current.log("the server agent carries on every session that was running (launchd starts it with no list): \(sessions)")
        }
        return nil
    }

    /// Exits: the agents have been ended or left already. 0, so launchd
    /// leaves it ended.
    @MainActor
    public func terminate() {
        exit(0)
    }

    /// A bundle's Info.plist, read afresh (Bundle(path:) keeps what it read
    /// first of a path).
    static func info(of bundle: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// "0.62.7", as a bundle names its version (the job's VISOR_VERSION).
    static func version(_ info: [String: Any]) -> String {
        VersionTitle.of(version: info["CFBundleShortVersionString"] as? String ?? "?", build: info["CFBundleVersion"] as? String)
    }
}

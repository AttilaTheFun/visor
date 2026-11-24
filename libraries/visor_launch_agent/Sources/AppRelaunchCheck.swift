// Whether the menu bar app relaunches into the bundle on disk. An update
// replaces /Applications/Visor.app and restarts the server agent
// (ServerAgentRestart), but the app, the same bundle opened as an app, ran
// on: on Logan's Macs, 0.64.1's and 0.65.1's for days beside a 0.69.1
// server, old code talking to a newer server, and Shireworks never told
// the build installed (the app's UpdateKit writes that at its start,
// VisorUpdates). So the app looks at its bundle on disk when it learns the
// server restarted, and every few minutes besides, and relaunches when
// that is another build (MacAppRelaunch).
//
// What's decided is here, tested on Linux (//tests/visor_launch_agent_tests);
// the app looks and relaunches. The bundle's Info.plist is read afresh
// (Bundle(path:) keeps what it read first of a path), and nothing is
// relaunched into a bundle that isn't whole yet, nor while an update's
// watch holds its lock (RelaunchWatchLock: it may still put the previous
// build back), nor from a copy outside /Applications (a build to run here).

import Foundation
import VisorProtocol
import VisorServer

public enum AppRelaunchCheck {
    /// A bundle's identifier, version and build, as its Info.plist says.
    public struct Build: Equatable, Sendable {
        public var identifier: String?
        /// CFBundleShortVersionString.
        public var version: String?
        /// CFBundleVersion.
        public var build: String?

        public init(identifier: String?, version: String?, build: String?) {
            self.identifier = identifier
            self.version = version
            self.build = build
        }

        public init(info: [String: Any]) {
            self.init(identifier: info["CFBundleIdentifier"] as? String, version: info["CFBundleShortVersionString"] as? String,
                      build: info["CFBundleVersion"] as? String)
        }

        /// "0.69.1", as a build names its version.
        public var title: String { VersionTitle.of(version: version ?? "?", build: build) }
    }

    /// The bundle on disk: whole, its build; or not (yet), and why.
    public enum OnDisk: Equatable, Sendable {
        case whole(Build)
        case incomplete(String)
    }

    /// What the app does.
    public enum Decision: Equatable, Sendable {
        /// Runs on: why.
        case stay(String)
        /// Runs on for now, and looks again in `seconds`: why.
        case later(String, seconds: Int)
        /// Relaunches into the bundle on disk: why.
        case relaunch(String)

        public var relaunches: Bool {
            if case .relaunch = self { return true }
            return false
        }
    }

    /// The bundle at `bundle` as it is now: whole when its Info.plist reads,
    /// with a version, and the executable it names is in Contents/MacOS.
    public static func onDisk(_ bundle: String) -> OnDisk {
        guard let data = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist"),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return .incomplete("\(bundle) has no readable Info.plist")
        }
        let build = Build(info: info)
        guard build.version != nil || build.build != nil else { return .incomplete("\(bundle)'s Info.plist names no version") }
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty else {
            return .incomplete("\(bundle)'s Info.plist names no executable")
        }
        let path = bundle + "/Contents/MacOS/" + executable
        guard FileManager.default.isExecutableFile(atPath: path) else { return .incomplete("\(path) isn't there (yet)") }
        return .whole(build)
    }

    /// Whether `bundle` is an app in /Applications itself: what an update
    /// replaces (LaunchAgentJob.installProblem's place).
    public static func inApplications(_ bundle: String) -> Bool {
        let path = (bundle as NSString).standardizingPath
        guard path.hasPrefix(LaunchAgentJob.installedFolder), path.hasSuffix(".app") else { return false }
        return !path.dropFirst(LaunchAgentJob.installedFolder.count).contains("/")
    }

    /// How long an update's watch has left while a live watcher holds its
    /// lock (the lock file's text), or nil: RelaunchWatchLock's.
    public static func watchLeft(lock: String?, now: Int, isRunning: (Int32) -> Bool) -> Int? {
        RelaunchWatchLock.remaining(lock, now: now, isRunning: isRunning)
    }

    /// The decision: a relaunch only from an app in /Applications, with no
    /// update's watch running (`watchLeft`), into a whole bundle of this
    /// app's that is another version or build than `running` (what this
    /// process's Info.plist said at its launch).
    public static func decide(running: Build, inApplications: Bool, onDisk: OnDisk, watchLeft: Int?) -> Decision {
        guard inApplications else { return .stay("this copy isn't in /Applications (a build to run here): no update replaces it") }
        if let watchLeft {
            return .later("an update's watch is still running (\(watchLeft) s at most): it may yet put the previous build back",
                          seconds: watchLeft)
        }
        switch onDisk {
        case .incomplete(let why):
            return .stay("the bundle isn't whole: \(why)")
        case .whole(let disk):
            if let theirs = disk.identifier, let ours = running.identifier, theirs != ours {
                return .stay("the bundle on disk is \(theirs), not \(ours)")
            }
            guard disk.version != running.version || disk.build != running.build else {
                return .stay("the bundle on disk is the build running (\(running.title))")
            }
            return .relaunch("the bundle on disk is \(disk.title), this process runs \(running.title)")
        }
    }
}

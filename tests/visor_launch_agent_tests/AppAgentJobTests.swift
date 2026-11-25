// Visor.app's own launchd agent (0.72.1): its plist as the app bundle
// carries it (SMAppService registers it), whose program is the app itself,
// started at login and again after a crash, never after Quit; and what a
// launch of the app does: one instance at a time, handed to launchd where
// it can be. And the lock that keeps it to one.

import Foundation
import Testing
@testable import VisorLaunchAgent
import VisorServer

@Suite struct AppAgentJobTests {
    let bundleID = "com.LoganShire.Visor"

    @Test func itsPlistRunsTheAppItselfAndStartsItAgainOnlyAfterACrash() {
        #expect(AppAgentJob.label(bundleID: bundleID) == "com.LoganShire.Visor.app")
        #expect(AppAgentJob.plistName(bundleID: bundleID) == "com.LoganShire.Visor.app.plist")
        #expect(AppAgentJob.label(bundleID: bundleID) != ServerAgentJob.label(bundleID: bundleID), "not the server agent's job")
        let plist = AppAgentJob.bundledPlist(bundleID: bundleID)
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/Visor")
        #expect(plist["ProgramArguments"] as? [String] == ["Contents/MacOS/Visor"], "the app, menu bar and all: no --server")
        #expect(!(plist["ProgramArguments"] as? [String] ?? []).contains(ServerAgentJob.argument))
        #expect(plist["RunAtLoad"] as? Bool == true, "started at login")
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false], "started again after a crash; Quit (an exit of 0) stays quit")
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua", "a person's graphical session alone")
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["AbandonProcessGroup"] as? Bool == true, "the agents' hosts and the update's watcher outlive it")
        #expect((plist["EnvironmentVariables"] as? [String: String]) == [AppAgentJob.environmentVariable: "1"], "the app knows launchd started it")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [bundleID])
        #expect(plist["StandardErrorPath"] == nil, "nothing in the home folder")
    }

    /// The plist in applications/visor_mac/LaunchAgents is the one the
    /// code means: what the bundle carries.
    @Test func theCheckedInPlistIsAppAgentJobs() throws {
        let runfiles = try #require(ProcessInfo.processInfo.environment["TEST_SRCDIR"])
        let path = runfiles + "/_main/applications/visor_mac/LaunchAgents/com.LoganShire.Visor.app.plist"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Both written the same way (an XML plist's keys are sorted), then compared.
        let read = try PropertyListSerialization.propertyList(from: data, format: nil)
        func xml(_ plist: Any) throws -> String {
            String(decoding: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), as: UTF8.self)
        }
        #expect(try xml(read) == xml(AppAgentJob.bundledPlist(bundleID: bundleID)))
    }

    @Test func itsWantedUnlessTurnedOff() {
        #expect(AppAgentJob.wanted(nil), "on by default, as the server agent was")
        #expect(AppAgentJob.wanted(true))
        #expect(!AppAgentJob.wanted(false))
    }

    @Test func oneInstanceAtATimeHandedToLaunchdWhereItCanBe() {
        #expect(LaunchAgentJob.installProblem("/Applications/Visor.app/Contents/MacOS/Visor") == nil)
        let elsewhere = LaunchAgentJob.installProblem("/Users/me/build/Visor.app/Contents/MacOS/Visor")
        #expect(elsewhere != nil)
        func launch(held: Bool = false, agent: Bool = false, without: Bool = false, wanted: Bool = true,
                    problem: String? = nil) -> AppAgentJob.Launch {
            AppAgentJob.launch(lockHeld: held, fromAgent: agent, withoutAgent: without, wanted: wanted, installProblem: problem)
        }
        // A second instance ends at once (an exit of 0: KeepAlive leaves it).
        #expect(launch(held: true) == .second(showFirst: true), "a person's open: the first comes forward")
        #expect(launch(held: true, without: true) == .second(showFirst: false),
                "the watcher's open that lost to launchd's copy, mid-update: the window is the present marker's alone")
        #expect(launch(held: true, agent: true) == .second(showFirst: false), "launchd's restart that met a person's open: quiet")
        #expect(launch(held: true, wanted: false, problem: elsewhere) == .second(showFirst: true), "whatever the copy")
        // launchd's own, and the watcher's fallback, run where they are.
        #expect(launch(agent: true) == .run)
        #expect(launch(agent: true, wanted: false) == .run, "Start at Login just turned off: the watcher unregisters it")
        #expect(launch(without: true) == .run, "launchd didn't start it: never asked again in a loop")
        // A person's open: launchd's, so a crash is answered.
        #expect(launch() == .handToLaunchd)
        #expect(launch(wanted: false) == .run, "Start at Login off")
        #expect(launch(problem: elsewhere) == .run, "a build to run here registers nothing")
    }

    /// NCH's check of #537: a copy outside /Applications served this Mac's
    /// data whenever nothing held the lock. It's a client alone, unless a
    /// test's or a developer's setting says it may serve.
    @Test func aCopyOutsideApplicationsIsAClientAlone() throws {
        #expect(AppAgentJob.clientOnly(installProblem: nil, servesAnyway: false) == nil, "the copy in /Applications serves")
        let elsewhere = try #require(LaunchAgentJob.installProblem("/Users/me/Downloads/Visor.app/Contents/MacOS/Visor"))
        let reason = try #require(AppAgentJob.clientOnly(installProblem: elsewhere, servesAnyway: false))
        #expect(reason.contains("client alone") && reason.contains(AppAgentJob.servesOutsideKey))
        #expect(AppAgentJob.clientOnly(installProblem: elsewhere, servesAnyway: true) == nil, "CI's launch check, a build to run here")
    }
}

/// The window at a launch (Logan, 25 Nov 2026): launchd's own, at login
/// and after a crash, keeps to the menu bar; a person's open shows it, and
/// so does launchd's process a person's open was handed to.
@Suite struct WindowAtLaunchTests {
    let now = 1_795_000_000

    @Test func launchdAtLoginOrAfterACrashKeepsToTheMenuBar() {
        #expect(!AppAgentJob.showsWindow(fromAgent: true, askedAt: nil, now: now))
    }

    @Test func aPersonsOpenShowsTheWindow() {
        #expect(AppAgentJob.showsWindow(fromAgent: false, askedAt: nil, now: now), "the Finder, the Dock, open")
        #expect(AppAgentJob.showsWindow(fromAgent: false, askedAt: now - 3_600, now: now), "whatever marker is about")
    }

    @Test func aPersonsOpenHandedToLaunchdShowsTheWindow() {
        #expect(AppAgentJob.showsWindow(fromAgent: true, askedAt: now - 2, now: now))
        #expect(AppAgentJob.showsWindow(fromAgent: true, askedAt: now - AppAgentJob.presentWithin, now: now), "a slow registration")
    }

    @Test func anOldOrStrangeMarkerSaysNothing() {
        #expect(!AppAgentJob.showsWindow(fromAgent: true, askedAt: now - AppAgentJob.presentWithin - 1, now: now),
                "a hand-off that came to nothing: a crash's restart later stays in the menu bar")
        #expect(!AppAgentJob.showsWindow(fromAgent: true, askedAt: now + 30, now: now), "from the future")
    }

    @Test func theMarkerIsBesideTheLockAndSaysWhenItWasWritten() {
        #expect(AppAgentJob.presentMarker(bundleID: "com.LoganShire.Visor", temporary: "/var/folders/xy/T")
            == "/var/folders/xy/T/com.LoganShire.Visor.present")
        #expect(AppAgentJob.askedAt("1795000000\n") == 1_795_000_000)
        #expect(AppAgentJob.askedAt(nil) == nil)
        #expect(AppAgentJob.askedAt("nonsense") == nil)
    }
}

@Suite(.serialized) struct InstanceLockTests {
    private func path() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("visor-instance-\(UUID().uuidString).lock").path
    }

    @Test func oneHolderAtATime() throws {
        let path = path()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(!InstanceLock.isHeld(path))
        let first = try #require(try InstanceLock.take(path))
        #expect(InstanceLock.isHeld(path), "asked by another open of it, as another process asks")
        #expect(try InstanceLock.take(path) == nil, "a second can't take it")
        #expect(InstanceLock.holder(path) == ProcessInfo.processInfo.processIdentifier, "the holder's process id, for the second to bring forward")
        #expect(InstanceLock.isHeld(path), "asking let nothing go")
        first.release()
        #expect(!InstanceLock.isHeld(path), "let go when its holder ends")
        let second = try #require(try InstanceLock.take(path))
        second.release()
    }

    @Test func aStaleFileKeepsNobodyOut() throws {
        let path = path()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "4242\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(!InstanceLock.isHeld(path), "a crashed holder's file: the lock went with its process")
        let taken = try #require(try InstanceLock.take(path))
        #expect(InstanceLock.holder(path) == ProcessInfo.processInfo.processIdentifier)
        taken.release()
    }

    /// NCH's check of #537: a lock that can't be opened held nothing and
    /// let the copy run its server unguarded. It fails closed now: not
    /// held, and taking it throws, so the copy runs no server.
    @Test func aLockThatCantBeOpenedFailsClosed() throws {
        let path = path()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // A folder where the file should be: open(2) refuses it.
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(!InstanceLock.isHeld(path), "not held: nobody holds it")
        #expect(throws: InstanceLock.Unavailable.self, "and not taken: never a lock that holds nothing") {
            _ = try InstanceLock.take(path)
        }
        let missing = path + "/no/such/folder/visor.lock"
        #expect(throws: InstanceLock.Unavailable.self) { _ = try InstanceLock.take(missing) }
    }

    @Test func itsInTheUsersTemporaryFolder() {
        #expect(InstanceLock.path(bundleID: "com.LoganShire.Visor", temporary: "/var/folders/xy/T") == "/var/folders/xy/T/com.LoganShire.Visor.instance.lock")
    }
}

/// NCH's check of #537: an update watch's lock left behind, its pid since
/// reused by another process, held the hand-back up for a whole watch. Its
/// holder must have started when the lock says its watcher did.
@Suite(.serialized) struct RelaunchWatchHolderTests {
    /// A process running now, for as long as the test needs it.
    private func running() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test func aWatcherThatStartedWhenItsLockSaysHoldsIt() throws {
        let watcher = try running()
        defer { watcher.terminate() }
        let now = Int(Date().timeIntervalSince1970)
        let started = try #require(RelaunchWatchHolder.startTime(watcher.processIdentifier), "the system says when it started")
        #expect(abs(started - now) <= 5)
        #expect(RelaunchWatchHolder.remaining("\(watcher.processIdentifier) \(now)\n", now: now) != nil, "its watch is waited for")
    }

    @Test func aReusedPidHoldsNothing() throws {
        let other = try running()
        defer { other.terminate() }
        let now = Int(Date().timeIntervalSince1970)
        // The lock says its watcher started an hour ago; the process with
        // that pid now started just now: another process.
        let lock = "\(other.processIdentifier) \(now - 3_600)\n"
        #expect(RelaunchWatchLock.remaining(lock, now: now, isRunning: { _ in true }) != nil, "a live pid alone would have held it")
        #expect(RelaunchWatchHolder.remaining(lock, now: now) == nil, "it's stale: not waited for")
        #expect(!RelaunchWatchHolder.isWatcher(other.processIdentifier, recorded: now - 3_600))
    }

    @Test func aGoneWatcherHoldsNothing() {
        #expect(RelaunchWatchHolder.remaining("4242 1795000000", now: 1_795_000_100, started: { _ in nil }) == nil)
        #expect(RelaunchWatchHolder.remaining(nil, now: 0) == nil)
        #expect(RelaunchWatchHolder.remaining("nonsense", now: 0) == nil)
    }
}

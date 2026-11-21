// The server agent's launchd job: its plist as the app bundle carries it
// (SMAppService registers it), and what's decided from what's there; and
// agent-proxy's LaunchAgentJob, still written to ~/Library/LaunchAgents.

import Foundation
import Testing
@testable import VisorLaunchAgent

@Suite struct ServerAgentJobTests {
    let app = "/Applications/Visor.app/Contents/MacOS/Visor"

    @Test func itsPlistIsTheBundlesAndRunsTheAppsOwnExecutableAsTheServer() throws {
        let job = ServerAgentJob.job(bundleID: "com.LoganShire.Visor", home: "/Users/me")
        #expect(job.label == "com.LoganShire.Visor.server")
        #expect(job.log == "/Users/me/Library/Logs/Visor-server.log")
        #expect(ServerAgentJob.job(bundleID: "com.LoganShire.Visor", logs: "/Volumes/Visor/Logs").log == "/Volumes/Visor/Logs/Visor-server.log")
        #expect(ServerAgentJob.plistName(bundleID: "com.LoganShire.Visor") == "com.LoganShire.Visor.server.plist")
        #expect(ServerAgentJob.bundledPlistPath(bundleID: "com.LoganShire.Visor", bundle: "/Applications/Visor.app")
            == "/Applications/Visor.app/Contents/Library/LaunchAgents/com.LoganShire.Visor.server.plist")
        #expect(ServerAgentJob.legacyPlistPath(bundleID: "com.LoganShire.Visor", home: "/Users/me")
            == "/Users/me/Library/LaunchAgents/com.LoganShire.Visor.server.plist")
        let plist = ServerAgentJob.bundledPlist(bundleID: "com.LoganShire.Visor")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/Visor")
        #expect(plist["ProgramArguments"] as? [String] == ["Contents/MacOS/Visor", "--server"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false], "started again after a failure; a stop asked for stays")
        #expect(plist["AbandonProcessGroup"] as? Bool == true, "the agents' hosts and the watcher outlive it")
        #expect(plist["StandardErrorPath"] == nil, "nothing in the home folder: the agent opens its log itself")
        #expect(plist["EnvironmentVariables"] == nil)
    }

    /// The plist in applications/visor_mac/LaunchAgents is the one the
    /// code means: what the bundle carries.
    @Test func theCheckedInPlistIsServerAgentJobs() throws {
        let runfiles = try #require(ProcessInfo.processInfo.environment["TEST_SRCDIR"])
        let path = runfiles + "/_main/applications/visor_mac/LaunchAgents/com.LoganShire.Visor.server.plist"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Both written the same way (an XML plist's keys are sorted), then compared.
        let read = try PropertyListSerialization.propertyList(from: data, format: nil)
        func xml(_ plist: Any) throws -> String {
            String(decoding: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), as: UTF8.self)
        }
        #expect(try xml(read) == xml(ServerAgentJob.bundledPlist(bundleID: "com.LoganShire.Visor")))
    }

    @Test func itsSettledAsTheSettingAndTheAppSay() {
        func decide(_ wanted: Bool, _ status: ServerAgentJob.ServiceStatus, legacy: Bool = false, running: Bool?,
                    executable: String? = nil) -> LaunchAgentJob.Action {
            ServerAgentJob.decide(wanted: wanted, executable: executable ?? app, status: status, legacyPlist: legacy, running: running)
        }
        // Off, and nothing there: nothing at all (Logan's Macs until it's on).
        #expect(decide(false, .notRegistered, running: false) == .nothing)
        #expect(decide(false, .notFound, running: false) == .nothing)
        #expect(decide(false, .enabled, running: true) == .stop)
        #expect(decide(false, .enabled, running: false) == .stop)
        #expect(decide(false, .notRegistered, legacy: true, running: true) == .stop, "0.64's job goes too")
        #expect(decide(true, .notRegistered, running: false) == .start)
        #expect(decide(true, .enabled, running: false) == .start, "stopped (/api/quit): started again by the app")
        #expect(decide(true, .enabled, running: true) == .leave, "the app's launch cuts nothing")
        #expect(decide(true, .notRegistered, legacy: true, running: true)
                == .restart("0.64's plist in ~/Library/LaunchAgents gives way to the app's own"))
        #expect(decide(true, .requiresApproval, running: false) == .hold("it waits to be allowed in System Settings › General › Login Items"))
        #expect(decide(true, .enabled, running: nil) == .hold("launchd didn't say whether it runs"))
        for elsewhere in ["/Users/me/bazel-bin/applications/visor_mac/Visor.app/Contents/MacOS/Visor", "/tmp/Visor.app/Contents/MacOS/Visor"] {
            if case .refuse = decide(true, .notRegistered, running: false, executable: elsewhere) {} else {
                Issue.record("a copy outside /Applications never registers it")
            }
            if case .refuse = decide(false, .enabled, running: true, executable: elsewhere) {} else {
                Issue.record("nor removes it")
            }
        }
    }

    @Test func thePidIsReadFromWhatLaunchctlPrints() {
        let print = """
        gui/501/com.LoganShire.Visor.server = {
        \tactive count = 1
        \tpath = /Users/me/Library/LaunchAgents/com.LoganShire.Visor.server.plist
        \tstate = running
        \tprogram = /Applications/Visor.app/Contents/MacOS/Visor
        \tpid = 4242
        \tlast exit code = 0
        }
        """
        #expect(LaunchAgentJob.pid(inPrint: print) == 4242)
        #expect(LaunchAgentJob.pid(inPrint: "\tstate = not running\n\tlast exit code = 1\n") == nil)
    }
}

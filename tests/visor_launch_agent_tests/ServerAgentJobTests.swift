// The server agent's launchd job: its plist as written and read back, and
// what's decided from what's there, as agent-proxy's job is
// (AgentProxyHostTests): the same LaunchAgentJob.

import Foundation
import Testing
@testable import VisorLaunchAgent

@Suite struct ServerAgentJobTests {
    let app = "/Applications/Visor.app/Contents/MacOS/Visor"

    @Test func itsPlistRunsTheAppsOwnExecutableAsTheServer() throws {
        let job = ServerAgentJob.job(bundleID: "com.LoganShire.Visor", home: "/Users/me")
        #expect(job.label == "com.LoganShire.Visor.server")
        #expect(job.plistPath == "/Users/me/Library/LaunchAgents/com.LoganShire.Visor.server.plist")
        #expect(job.log == "/Users/me/Library/Logs/Visor-server.log")
        let plist = job.plist(executable: app, version: "0.62.4", settings: nil)
        #expect(plist["ProgramArguments"] as? [String] == [app, "--server"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false], "started again after a failure; a stop asked for stays")
        #expect(plist["AbandonProcessGroup"] as? Bool == true, "the agents' hosts and the watcher outlive it")
        #expect(plist["StandardErrorPath"] as? String == "/Users/me/Library/Logs/Visor-server.log")
        #expect((plist["EnvironmentVariables"] as? [String: String]) == ["VISOR_VERSION": "0.62.4"], "no settings digest: it has none")
        let data = try job.plistData(executable: app, version: "0.62.4", settings: nil)
        #expect(job.read(data) == LaunchAgentJob.Plist(program: [app, "--server"], version: "0.62.4", settings: nil),
                "what it writes is what it reads back")
        #expect(job.read(Data("not a plist".utf8)) == nil)
        // agent-proxy's has no AbandonProcessGroup: nothing of its outlives it.
        let proxy = LaunchAgentJob(label: "x.agent-proxy", argument: "--agent-proxy", name: "agent-proxy", log: "/tmp/l",
                                   settingsVariable: "S", settingsName: "agentProxy")
        #expect(proxy.plist(executable: app, version: "1", settings: "d")["AbandonProcessGroup"] == nil)
    }

    @Test func itsSettledAsTheSettingAndTheAppSay() {
        let job = ServerAgentJob.job(bundleID: "com.LoganShire.Visor")
        let plist = LaunchAgentJob.Plist(program: [app, "--server"], version: "0.62.4", settings: nil)
        func state(_ wanted: Bool, plist: LaunchAgentJob.Plist?, running: Bool?, executable: String? = nil, version: String = "0.62.4")
            -> LaunchAgentJob.State {
            LaunchAgentJob.State(configured: wanted, executable: executable ?? app, version: version, settings: nil, plist: plist, running: running)
        }
        // Off, and nothing there: nothing at all (Logan's Macs until it's on).
        #expect(job.decide(state(false, plist: nil, running: false)) == .nothing)
        #expect(job.decide(state(false, plist: plist, running: true)) == .stop)
        #expect(job.decide(state(false, plist: plist, running: false)) == .stop)
        #expect(job.decide(state(true, plist: nil, running: false)) == .start)
        #expect(job.decide(state(true, plist: plist, running: false)) == .start, "stopped (/api/quit): started again by the app")
        #expect(job.decide(state(true, plist: plist, running: true)) == .leave, "the app's launch cuts nothing")
        #expect(job.decide(state(true, plist: plist, running: true, version: "0.62.5")) == .restart("its plist is 0.62.4, this is 0.62.5"))
        #expect(job.decide(state(true, plist: LaunchAgentJob.Plist(program: ["/Applications/Old.app/Contents/MacOS/Visor", "--server"],
                                                                   version: "0.62.4", settings: nil), running: true))
                == .restart("its plist runs /Applications/Old.app/Contents/MacOS/Visor --server"))
        #expect(job.decide(state(true, plist: plist, running: nil)) == .hold("launchd didn't say whether it runs"))
        for elsewhere in ["/Users/me/bazel-bin/applications/visor_mac/Visor.app/Contents/MacOS/Visor", "/tmp/Visor.app/Contents/MacOS/Visor"] {
            if case .refuse = job.decide(state(true, plist: nil, running: false, executable: elsewhere)) {} else {
                Issue.record("a copy outside /Applications never writes the job")
            }
            if case .refuse = job.decide(state(false, plist: plist, running: true, executable: elsewhere)) {} else {
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

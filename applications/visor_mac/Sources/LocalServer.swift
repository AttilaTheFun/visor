// This Mac's server, as Visor.app has it: in the app's own process, as it
// has always been, or, with the app's `ServerAsAgent` default on, the
// server agent (`Visor --server`, ServerAgentJob), with the app its client
// (docs/DEVELOPMENT.md, The server as a background agent).
//
// Off (the default) and no agent installed: the server is made in the app
// at its launch, exactly as before, and nothing else is looked at. On, or
// an agent there from when it was: the app makes no server of its own until
// the hand-over has decided (ServerHandOver): the agent installed, started
// and answering, and the app is its client; or the agent removed (it leaves
// the agents' hosts running), and the server made in the app after all.
//
// In the app, its window reaches the server as any client does, at this
// Mac's loopback with the password (OwnServer), whichever process serves.
// What the app still does to the server in its own process (its menu,
// Settings, the welcome, updates) is in-app only; as the agent's client it
// does what it can over the server's socket file (MacServerCalls), and the
// rest waits for the app to be wholly a client (0b).

import AppKit
import Foundation
import Observation
import VisorClient
import VisorLaunchAgent
import VisorServer
import VisorServerApple

@MainActor
@Observable
final class LocalServer {
    static let shared = LocalServer()

    enum Mode: Equatable {
        /// The server runs in the app.
        case inApp
        /// The hand-over is being decided: no server in the app yet.
        case handingOver
        /// The server agent serves; the app is its client.
        case agent
    }

    private(set) var mode: Mode = .inApp
    /// The server in the app, while it runs there.
    private(set) var server: VisorServer?
    /// What the hand-over said, for the menu: why the server runs in the
    /// app after all, when it was wanted as an agent.
    private(set) var note: String?
    /// The client's store, once there is one: this Mac's server is added to
    /// it when the hand-over has decided.
    private var store: VisorStore?

    /// Whether the server runs as the agent: the app's default.
    static var wanted: Bool { UserDefaults.standard.bool(forKey: ServerAgentJob.defaultsKey) }
    static var job: LaunchAgentJob { ServerAgentJob.job(bundleID: MacPlaces.own) }

    /// At the app's launch, before its window: the server made in the app,
    /// as before, unless the agent is wanted or there; then the hand-over.
    func begin() {
        if VisorFixture.active || (!Self.wanted && !FileManager.default.fileExists(atPath: Self.job.plistPath)) {
            server = MacServer.make()
            mode = .inApp
            return
        }
        mode = .handingOver
        Task { await handOver() }
    }

    /// Once launched (AppDelegate): the server in the app listens.
    func launched() {
        server?.start()
    }

    /// The client's store: this Mac's server added to it once it's known
    /// which serves.
    func follow(in store: VisorStore) {
        self.store = store
        switch mode {
        case .inApp: if let server { OwnServer.follow(server, in: store) }
        case .agent: OwnServer.followAgent(in: store)
        case .handingOver: break
        }
    }

    /// Whether this Mac's server serves: the menu bar's eye.
    var serving: Bool { server?.listening ?? (mode == .agent) }

    /// Whether Settings should open for a password: only the app's own
    /// server's.
    var needsPassword: Bool {
        guard let server else { return false }
        return server.password.isEmpty
    }

    private func handOver() async {
        let log: @Sendable (String) -> Void = { ServerPlatform.current.log($0) }
        let steps = LaunchdHandOverSteps(job: Self.job, version: VisorMacApp.bundleVersion, log: log)
        let outcome = await ServerHandOver.run(wanted: Self.wanted, hasPassword: MacServer.hasPassword, steps: steps, log: log)
        switch outcome {
        case .agent(let pid):
            log("Visor is the client of the server agent (process \(pid))")
            mode = .agent
            if let store { OwnServer.followAgent(in: store) }
        case .inApp(let why):
            if let why { log(why) }
            note = why
            let server = MacServer.make()
            self.server = server
            mode = .inApp
            server.start()
            if let store { OwnServer.follow(server, in: store) }
            MacAgentProxy.settle()
            // As at a launch without one: there is no serving without it.
            if server.password.isEmpty { AppDelegate.openSettings() }
        }
    }

    // MARK: Updates, as the agent's client

    /// The verified build at `path` installed by the server agent (its
    /// restart into it, watched and rolled back as it says), then the app
    /// reopened from the bundle it installed. What went wrong, or nil.
    func installThroughAgent(_ path: String) async -> String? {
        let before = await MacServerCalls.version()
        if let problem = await MacServerCalls.restart(installing: path) { return problem }
        // The agent's first answer with the new build, then its watch: as
        // long as AppRelauncher gives a new build of the app.
        var answered: String?
        for _ in 0..<(AppRelauncher.firstAnswer / 2) {
            try? await Task.sleep(for: .seconds(2))
            if let now = await MacServerCalls.version(), now != before {
                answered = now
                break
            }
        }
        guard let answered else { return "the server agent did not come back with the new build" }
        for _ in 0..<(AppRelauncher.watch / 2) {
            try? await Task.sleep(for: .seconds(2))
            if let now = await MacServerCalls.version(), now != answered {
                return "the server agent's new build did not stay up (it's back at \(now))"
            }
        }
        reopen()
        return nil
    }

    /// The app ended and opened again from its bundle, by a shell that
    /// outlives it. The server agent runs on throughout.
    func reopen() {
        let bundle = Bundle.main.bundlePath
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; sleep 0.5; "
            + "open -a \(ServerAgentWatch.quoted(bundle))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        guard (try? process.run()) != nil else { return }
        NSApplication.shared.terminate(nil)
    }
}

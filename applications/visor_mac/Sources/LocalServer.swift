// This Mac's server, as Visor.app has it: the server agent (`Visor
// --server`, ServerAgentJob), with the app its client, while the app's
// `ServerAsAgent` default is on; or, until the agent is the only way (one
// release), the server in the app's own process, as it has always been
// (docs/DEVELOPMENT.md, The server as a background agent).
//
// Off (the default) and no agent installed: the server is made in the app
// at its launch, exactly as before, and nothing else is looked at. On, or
// an agent there from when it was: the app makes no server of its own until
// the hand-over has decided (ServerHandOver): the agent installed, started
// and answering, and the app is its client; or the agent removed (it leaves
// the agents' hosts running), and the server made in the app after all.
//
// Either way the app is only ever the server's client: its window, its
// menu, Settings, the welcome and its updates reach the server at its
// socket file (`/Volumes/Visor/run/server.sock` on the Visor volume, else
// `~/.visor/server.sock`: SocketFileURL), as an SSH client
// does, with no password, through the same client (VisorAgentServer) that
// reaches any other computer. The server in the app's process is made and
// started here and touched by nothing else.

import AppKit
import Foundation
import Observation
import VisorClient
import VisorLaunchAgent
import VisorProtocol
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
    /// The server in the app's process, while it runs there: made and
    /// started here, and nothing else's to touch. Nil in agent mode.
    @ObservationIgnored private var server: VisorServer?
    /// What the hand-over said, for the menu: why the server runs in the
    /// app after all, when it was wanted as an agent.
    private(set) var note: String?
    /// How the server stands, as it last said (`GET /api/settings`); nil
    /// while it doesn't answer.
    private(set) var controls: ServerControls?
    /// Its sessions, as it last said.
    private(set) var sessions: [SessionInfo] = []
    /// Why it didn't answer, last time it was asked.
    private(set) var unreachable: String?
    /// The client's store, once there is one: this Mac's server is added to
    /// it once it answers with a password set.
    @ObservationIgnored private var store: VisorStore?
    @ObservationIgnored private var watching: Task<Void, Never>?

    /// The server, as the app's client reaches it: at its socket file, as
    /// this user, no password.
    let client = VisorAgentServer(record: OwnServer.record(name: Host.current().localizedName ?? "This Mac"))

    /// Whether the server runs as the agent: the app's default.
    static var wanted: Bool { UserDefaults.standard.bool(forKey: ServerAgentJob.defaultsKey) }
    static var job: LaunchAgentJob { ServerAgentJob.job(bundleID: MacPlaces.own, logs: MacPlaces.folders.logs.path) }

    /// Whether the server will be made in the app at its launch: the agent
    /// isn't wanted, nor registered (or 0.64's plist there).
    static var runsInApp: Bool {
        VisorFixture.active || (!wanted && !ServerAgentService.isRegisteredOrLegacy(bundleID: MacPlaces.own))
    }

    /// How often the menu's word of the server is asked for again.
    static let refreshInterval: Duration = .seconds(3)

    /// At the app's launch, before its window: the server made in the app,
    /// as before, unless the agent is wanted or there; then the hand-over.
    func begin() {
        if Self.runsInApp {
            server = MacServer.make()
            mode = .inApp
            return
        }
        mode = .handingOver
        Task { await handOver() }
    }

    /// Once launched (AppDelegate): the server in the app listens, and the
    /// app follows it from then on.
    func launched() {
        server?.start()
        watch()
    }

    /// The client's store: this Mac's server added to it once it answers.
    func follow(in store: VisorStore) {
        self.store = store
        join()
    }

    /// Whether this Mac's server serves: the menu bar's eye.
    var serving: Bool { controls?.listening ?? false }

    /// Whether Settings should open for a password: the server answers, and
    /// has none.
    var needsPassword: Bool { controls.map { !$0.hasPassword } ?? false }

    /// Asked again now: how it stands and its sessions.
    func refresh() async {
        guard mode != .handingOver else { return }
        do {
            let now = try await client.controls()
            controls = now
            unreachable = nil
            sessions = (try? await client.sessions()) ?? sessions
        } catch {
            controls = nil
            sessions = []
            unreachable = VisorAgentServer.problem(error)
        }
        join()
        askForPasswordIfNeeded()
    }

    /// Whether Settings has been opened for a password this launch.
    @ObservationIgnored private var askedForPassword = false

    /// Settings opened over the window, once, when the server answers with
    /// no password: there is no serving without one. Once the window can
    /// open it (SceneOpeners); not on the screenshot fixture, whose
    /// computer is canned.
    func askForPasswordIfNeeded() {
        guard !askedForPassword, needsPassword, AppDelegate.canOpenSettings, !VisorFixture.active else { return }
        askedForPassword = true
        AppDelegate.openSettings()
    }

    /// What a change of the server's own settings left it as.
    func take(_ controls: ServerControls) {
        self.controls = controls
        join()
    }

    /// A change of its settings, from Settings: why it was refused, or nil.
    @discardableResult
    func change(_ change: ServerControlsChange) async -> String? {
        do {
            take(try await client.change(change))
            return nil
        } catch {
            await refresh()
            return VisorAgentServer.problem(error)
        }
    }

    /// Asked every few seconds, for the menu bar's eye and the menu.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// This Mac's server in the store, once it answers with a password set.
    private func join() {
        guard let store, !VisorFixture.active, let controls, controls.hasPassword else { return }
        OwnServer.join(controls, in: store)
    }

    private func handOver() async {
        let log: @Sendable (String) -> Void = { ServerPlatform.current.log($0) }
        // What macOS keeps it waiting on, in the menu meanwhile.
        let steps = LaunchdHandOverSteps(job: Self.job, bundleID: MacPlaces.own, notice: { [weak self] text in
            Task { @MainActor in self?.note = text }
        }, log: log)
        let outcome = await ServerHandOver.run(wanted: Self.wanted, steps: steps, log: log)
        switch outcome {
        case .agent(let pid):
            log("Visor is the client of the server agent (process \(pid)); no server is made in the app")
            note = nil
            mode = .agent
        case .waiting(let why):
            // Wanted: never a server here, never the agent stopped. Its
            // socket file is asked every few seconds, as any computer's is.
            note = why
            mode = .agent
        case .inApp(let why):
            if let why { log(why) }
            note = why
            let server = MacServer.make()
            self.server = server
            mode = .inApp
            server.start()
            MacAgentProxy.settle()
        }
        await refresh()
    }

    // MARK: The server's own controls, as the menu has them

    /// Quit Visor: in the app's process, the server stops with it (its
    /// agents ended first, then the app: AppDelegate.applicationShouldTerminate
    /// asks for `/api/quit`); the server agent runs on, and the app quits
    /// alone.
    func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    /// Stop Server: the server agent stops (`/api/quit`, its agents ended),
    /// and launchd leaves it stopped until Start Server or the next login.
    func stopServer() async -> String? {
        do {
            try await client.quitServer()
        } catch {
            return VisorAgentServer.problem(error)
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
            if controls == nil { break }
        }
        return nil
    }

    /// Start Server: launchd starts the agent's job again.
    func startServer() async -> String? {
        let started = await Launchctl.run(["kickstart", "\(Launchctl.domain)/\(Self.job.label)"])
        guard started?.status == 0 else { return "launchctl kickstart: \(started?.output ?? "didn't run")" }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
            if controls != nil { break }
        }
        return nil
    }

    /// Restart Server: the server restarts in place, its agents left
    /// running (`/api/restart`). In the app's process the app relaunches.
    func restartServer() async -> String? {
        do {
            try await client.restartServer(installing: nil)
            return nil
        } catch {
            return VisorAgentServer.problem(error)
        }
    }

    // MARK: Updates

    /// Whether any session is mid-turn, as the server says.
    func busy() async -> Bool {
        ((try? await client.sessions()) ?? []).contains { $0.busy }
    }

    /// The verified build at `path` installed by the server
    /// (`/api/restart {path}`). In the app's process the app relaunches into
    /// it (AppRelauncher, watched and rolled back); the server agent
    /// restarts into it (ServerAgentRestart, the same), and the app reopens
    /// from the bundle once the new build has stayed up. What went wrong,
    /// or nil.
    func install(_ path: String) async -> String? {
        guard mode == .agent else {
            do {
                try await client.restartServer(installing: path)
                return nil
            } catch {
                return VisorAgentServer.problem(error)
            }
        }
        let before = try? await client.controls().version
        do {
            try await client.restartServer(installing: path)
        } catch {
            return VisorAgentServer.problem(error)
        }
        // The agent's first answer with the new build, then its watch: as
        // long as AppRelauncher gives a new build of the app.
        var answered: String?
        for _ in 0..<(AppRelauncher.firstAnswer / 2) {
            try? await Task.sleep(for: .seconds(2))
            if let now = try? await client.controls().version, now != before {
                answered = now
                break
            }
        }
        guard let answered else { return "the server agent did not come back with the new build" }
        for _ in 0..<(AppRelauncher.watch / 2) {
            try? await Task.sleep(for: .seconds(2))
            if let now = try? await client.controls().version, now != answered {
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

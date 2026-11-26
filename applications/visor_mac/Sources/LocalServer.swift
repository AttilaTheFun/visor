// This Mac's server, as Visor.app has it: in the app's own process, the
// menu bar app's (0.72.1; Logan, 25 Nov 2026: "The background process IS
// the menu-bar app, so that I can always tell when it's running, and its
// windows are the clients." docs/DEVELOPMENT.md, The server in the app).
// The app is started at login, and again after a crash, by its own launchd
// agent (AppAgentJob, MacAppInstance: Start at Login); Quit Visor stops the
// server with it; an update relaunches it (AppRelauncher: its watch and
// rollback). The server agent of the builds before (`Visor --server`) is
// no longer a place it runs, and the `ServerAsAgent` default isn't read.
//
// At the launch, before the window: the server made in the app, unless the
// server agent is still registered (or 0.64's plist is there), or a server
// already answers at the socket file or on the port: then it's handed back
// first (ServerHandBack: the agent unregistered and stopped, stepping aside
// with the agents' hosts left running, its socket and port waited for), and
// the server made in the app once they're free, picking the hosts up.
//
// A launch opened while an update's watch held its lock (MacAppInstance:
// a build before 0.72.1's watcher, or the server agent's) runs here rather
// than hand itself to launchd, which that watcher would take for a quit;
// once the watch has ended and the server runs in the app, it does
// (`handOffOnceWatched`: a restart, which AppRelauncher makes through the
// app's agent, watched by this build's own watcher).
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
import VisorServerPOSIX

@MainActor
@Observable
final class LocalServer {
    static let shared = LocalServer()

    enum Mode: Equatable {
        /// The server runs in the app.
        case inApp
        /// The server agent is being handed back: no server in the app yet.
        case handingBack
        /// Another server answers and stays (a server agent this copy of
        /// the app may not remove): the app is its client alone.
        case elsewhere
    }

    private(set) var mode: Mode = .inApp
    /// The server in the app's process, while it runs there: made and
    /// started here, and nothing else's to touch.
    @ObservationIgnored private var server: VisorServer?
    /// What the hand-back says, for the menu and Settings, while it runs or
    /// when another server stays.
    private(set) var note: String?
    /// Whether the app's own launchd agent is wanted: Start at Login, which
    /// also starts Visor again after a crash (AppAgentJob).
    private(set) var startsAtLogin = AppAgentService.wanted
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
    @ObservationIgnored private var handingOff: Task<Void, Never>?

    /// The server, as the app's client reaches it: at its socket file, as
    /// this user, no password.
    let client = VisorAgentServer(record: OwnServer.record(name: Host.current().localizedName ?? "This Mac"))

    /// The server agent's job, as the hand-back reaches it in launchd.
    static var job: LaunchAgentJob { ServerAgentJob.job(bundleID: MacPlaces.own, logs: MacPlaces.folders.logs.path) }

    /// Whether the server agent may still be there (registered, or 0.64's
    /// plist): asked without launchd, before anything is settled, so the
    /// data is left where it is until it's handed back.
    static var agentMayBeThere: Bool {
        !VisorFixture.active && ServerAgentService.isRegisteredOrLegacy(bundleID: MacPlaces.own)
    }

    /// Why Start at Login can't be changed from this copy of the app (a
    /// build to run here, a copy outside /Applications), or nil.
    static var startsAtLoginProblem: String? { LaunchAgentJob.installProblem(LaunchAgentJob.ownExecutable) }

    /// How often the menu's word of the server is asked for again.
    static let refreshInterval: Duration = .seconds(3)

    /// At the app's launch, before its window: the server made in the app,
    /// or, with the server agent there or another server answering, the
    /// hand-back first.
    func begin(agentMayBeThere: Bool) {
        if let problem = MacAppInstance.noServer {
            // Not known to be the only Visor, or not the one in
            // /Applications: it serves nothing.
            note = "Visor runs no server of its own: \(problem)."
            mode = .elsewhere
            return
        }
        if VisorFixture.active || (!agentMayBeThere && !Self.serverAnswers) {
            server = MacServer.make()
            mode = .inApp
            return
        }
        mode = .handingBack
        note = "Handing this Mac's server back to Visor…"
        Task { await handBack() }
    }

    /// Once launched (AppDelegate): the server in the app listens, with the
    /// Sessions container's engine and agent-proxy beside it, and the app
    /// follows it from then on.
    func launched() {
        if let server { Self.run(server) }
        watch()
        handOffOnceWatched()
    }

    /// Whether a server answers already, at the socket files or on the
    /// port.
    private static var serverAnswers: Bool {
        POSIXUnixSocket.answers(VisorServer.socketPath) || POSIXUnixSocket.answers(VisorServer.legacySocketPath)
            || LaunchdHandBackSteps.portAnswers(Envelope.defaultPort)
    }

    /// The server listening: the screenshot fixture's alone, as it was.
    private static func run(_ server: VisorServer) {
        if VisorFixture.active {
            server.start()
        } else {
            MacServer.run(server)
        }
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
        guard mode != .handingBack else { return }
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

    /// The app opened while an update's watch held its lock, handed to
    /// launchd once it has ended (AppAgentJob.handOff): Restart Server's
    /// restart, which AppRelauncher makes through the app's agent (`Visor
    /// app-agent start`) and this build's watcher follows, so a crash is
    /// answered from then on. Until then a crash isn't, as before 0.72.1.
    /// Not while the hand-back runs: a restart asked then would reach the
    /// server agent. A refusal (a watch's 409) is asked again a few times.
    private func handOffOnceWatched() {
        guard MacAppInstance.handsOffAfterWatch, handingOff == nil else { return }
        let log: @Sendable (String) -> Void = { ServerPlatform.current.log($0) }
        handingOff = Task { [weak self] in
            var tries = 0
            while !Task.isCancelled, tries < AppAgentJob.handOffTries {
                try? await Task.sleep(for: AppAgentJob.watchPoll)
                guard let self else { return }
                switch AppAgentJob.handOff(watching: MacAppInstance.watchHeld(RelaunchWatchLock.url.path),
                                           serverInApp: mode == .inApp && server != nil, wanted: AppAgentService.wanted,
                                           installProblem: Self.startsAtLoginProblem) {
                case .wait: continue
                case .never: return
                case .now: break
                }
                log("the update's watch has ended: Visor hands itself to launchd (a restart through its agent)")
                tries += 1
                guard let problem = await restartServer() else { return }
                log("Visor couldn't hand itself to launchd yet: \(problem)")
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// This Mac's server in the store, once it answers with a password set.
    private func join() {
        guard let store, !VisorFixture.active, let controls, controls.hasPassword else { return }
        OwnServer.join(controls, in: store)
    }

    /// The server agent handed back (ServerHandBack), then the server made
    /// in the app; or, if another server stays, the app its client.
    private func handBack() async {
        let log: @Sendable (String) -> Void = { ServerPlatform.current.log($0) }
        let steps = LaunchdHandBackSteps(job: Self.job, bundleID: MacPlaces.own,
                                         sockets: [VisorServer.socketPath, VisorServer.legacySocketPath],
                                         lock: RelaunchWatchLock.url.path, askToQuit: { await LocalServer.quitOther() }, log: log)
        let outcome = await ServerHandBack.run(steps: steps, log: log)
        // The setting that put the server in the agent: read no more.
        UserDefaults.standard.removeObject(forKey: ServerAgentJob.defaultsKey)
        switch outcome {
        case .inApp(let done):
            if let done { log("\(done): the server starts in the app") }
            note = nil
            let server = MacServer.make()
            self.server = server
            mode = .inApp
            Self.run(server)
        case .elsewhere(let why):
            note = why
            mode = .elsewhere
        }
        await refresh()
    }

    /// `/api/quit` asked of the server that answers (the hand-back's last
    /// resort): what went wrong, or nil.
    private static func quitOther() async -> String? {
        do {
            try await shared.client.quitServer()
            return nil
        } catch {
            return VisorAgentServer.problem(error)
        }
    }

    // MARK: The server's own controls, as the menu has them

    /// Quit Visor: the server stops with it (its agents ended first, then
    /// the app, which exits 0: AppDelegate.applicationShouldTerminate asks
    /// for `/api/quit`), and launchd's KeepAlive leaves it stopped.
    func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    /// Restart Server: the server restarts in place, its agents left
    /// running (`/api/restart`): the app relaunches (AppRelauncher, through
    /// its launchd agent when it's wanted).
    func restartServer() async -> String? {
        do {
            try await client.restartServer(installing: nil)
            return nil
        } catch {
            return VisorAgentServer.problem(error)
        }
    }

    /// Start at Login turned on or off: the app's agent registered or not.
    /// Unregistering from a process launchd didn't start ends nothing, so
    /// it's done at once; otherwise the app restarts (its agents' hosts
    /// left running), and the relaunch's watcher registers the agent, which
    /// starts the app, or unregisters it once this process has gone and
    /// opens the app itself (`Visor app-agent start`). What went wrong, or
    /// nil.
    func setStartsAtLogin(_ on: Bool) async -> String? {
        guard on != startsAtLogin else { return nil }
        if let problem = Self.startsAtLoginProblem { return "Start at Login is for Visor in /Applications: \(problem)" }
        UserDefaults.standard.set(on, forKey: AppAgentJob.defaultsKey)
        startsAtLogin = on
        if !on, !MacAppInstance.fromAgent {
            return await AppAgentService.unregister(bundleID: MacPlaces.own)
        }
        if on == MacAppInstance.fromAgent { return nil }
        return await restartServer()
    }

    // MARK: Updates

    /// Whether any session is mid-turn, as the server says.
    func busy() async -> Bool {
        ((try? await client.sessions()) ?? []).contains { $0.busy }
    }

    /// The verified build at `path` installed by the server
    /// (`/api/restart {path}`): the app relaunches into it (AppRelauncher,
    /// watched and rolled back). What went wrong, or nil.
    func install(_ path: String) async -> String? {
        guard mode == .inApp else { return "This Mac's server isn't Visor's own yet: the update waits until it is" }
        do {
            try await client.restartServer(installing: path)
            return nil
        } catch {
            return VisorAgentServer.problem(error)
        }
    }
}

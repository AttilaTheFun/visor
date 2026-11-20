// Visor.app's updates from Applications (UpdateKit 0.17, docs/Updates.md
// there): it installs them itself. Applications quitting it would end every
// session's agent with it, so it answers each offer "install myself"; once
// the verified build is ready, it waits until no session is mid-turn, then
// installs it through the server's own relaunch (`/api/restart {path}`,
// over its socket file, whichever process serves: LocalServer), which
// keeps the agents running under their hosts and puts the old build back if
// the new one doesn't stay up: in the app's process the app relaunches
// (AppRelauncher); the server agent restarts into the build (watched and
// rolled back the same way: ServerAgentRestart), and the app reopens once
// the new build has stayed up. A rollback the server says is reported to
// Applications. Applications offers nothing until the app's
// "Update automatically" is on; a build without the app group (one from the
// public source) does nothing at all.

import Foundation
import UpdateKit

@MainActor
enum VisorUpdates {
    /// How often an install waiting for a quiet moment looks again.
    static let quietCheck: Duration = .seconds(30)

    /// At launch, after the server has started: the handler and the install
    /// hook, the build this is written for Applications, and, when the
    /// server says an update didn't stay up and was rolled back (its
    /// relauncher's word, or the server agent's watch's), that, once.
    static func start() {
        AppUpdates.register(autoUpdate: { _ in .installMyself })
        AppUpdates.register(install: { offer in await install(offer) })
        AppUpdates.start()
        Task { await reportRollback() }
    }

    /// The last rollback the server said, reported to Applications: kept, so
    /// the server agent, which outlives the app, isn't reported at each of
    /// its launches.
    private static let reportedKey = "visor.rollbackReported"

    /// The server's word of a rollback, once it is known which process
    /// serves and it has answered.
    static func reportRollback() async {
        for _ in 0..<60 {
            if LocalServer.shared.controls != nil { break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard let note = LocalServer.shared.controls?.updateNotice, note.contains("did not stay up") else { return }
        guard UserDefaults.standard.string(forKey: reportedKey) != note else { return }
        UserDefaults.standard.set(note, forKey: reportedKey)
        await AppUpdates.installFailed(note)
    }

    /// The verified build, installed once no session is mid-turn.
    static func install(_ offer: UpdateOffer) async {
        guard let bundle = offer.bundle else {
            await AppUpdates.installFailed("Applications handed over no build")
            return
        }
        // Until it's known which process serves.
        while LocalServer.shared.mode == .handingOver {
            try? await Task.sleep(for: .seconds(2))
        }
        while await LocalServer.shared.busy() {
            try? await Task.sleep(for: quietCheck)
        }
        await AppUpdates.installing()
        // Every session that was running is carried on (none is mid-turn).
        if let problem = await LocalServer.shared.install(bundle.path) {
            await AppUpdates.installFailed(problem)
        }
    }
}

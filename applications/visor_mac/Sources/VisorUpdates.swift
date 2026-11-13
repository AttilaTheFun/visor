// Visor.app's updates from Applications (UpdateKit 0.17, docs/Updates.md
// there): it installs them itself. Applications quitting it would end every
// session's agent with it, so it answers each offer "install myself"; once
// the verified build is ready, it waits until no session is mid-turn, then
// installs it through the server's own relaunch (AppRelauncher), which
// keeps the agents running under their hosts and puts the old build back if
// the new one doesn't stay up. Applications offers nothing until the app's
// "Update automatically" is on; a build without the app group (one from the
// public source) does nothing at all.

import Foundation
import UpdateKit
import VisorServer

@MainActor
enum VisorUpdates {
    /// How often an install waiting for a quiet moment looks again.
    static let quietCheck: Duration = .seconds(30)

    /// At launch, after the server has started: the handler and the install
    /// hook, the build this is written for Applications, and, when this
    /// launch is the old build put back after an update that didn't stay
    /// up, the relauncher's word of it.
    static func start() {
        AppUpdates.register(autoUpdate: { _ in .installMyself })
        AppUpdates.register(install: { offer in await install(offer) })
        AppUpdates.start()
        if let note = VisorServer.shared.updateNotice, note.contains("did not stay up") {
            Task { await AppUpdates.installFailed(note) }
        }
    }

    /// The verified build, installed once no session is mid-turn.
    static func install(_ offer: UpdateOffer) async {
        guard let bundle = offer.bundle else {
            await AppUpdates.installFailed("Applications handed over no build")
            return
        }
        while VisorServer.shared.sessions.contains(where: { $0.info.busy }) {
            try? await Task.sleep(for: quietCheck)
        }
        await AppUpdates.installing()
        // Empty: every session that was running is carried on.
        if let problem = VisorServer.shared.relaunch(installing: bundle.path, carrying: []) {
            await AppUpdates.installFailed(problem)
        }
    }
}

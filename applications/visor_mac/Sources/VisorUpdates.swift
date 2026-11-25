// Visor.app's updates from Shireworks (Shireworks Kit's ShireworksUpdates,
// docs/updates/Updates.md there): it installs them itself. Shireworks quitting it would end every
// session's agent with it, so it answers each offer "install myself"; once
// the verified build is ready, it waits until no session is mid-turn, then
// installs it through the server's own relaunch (`/api/restart {path}`,
// over its socket file, whichever process serves: LocalServer), which
// keeps the agents running under their hosts and puts the old build back if
// the new one doesn't stay up: in the app's process the app relaunches
// (AppRelauncher); the server agent restarts into the build (watched and
// rolled back the same way: ServerAgentRestart), and the app reopens once
// the new build has stayed up. A rollback the server says is reported to
// Shireworks. The build handed over lies in the app group's container,
// which every member of the group may write: it's installed only as a
// real folder, copied out into Visor's own and that copy checked against
// Visor's identifier, Developer ID and the team the kernel holds this
// process signed for, and by the system's own assessment (HandedOverBuild),
// or not at all, the app
// staying as it is and Shireworks told why. Shireworks offers nothing
// until the app's "Update automatically" is on; a build without the app
// group (one from the public source) does nothing at all.

import Foundation
import Security
import ShireworksKit
import VisorUpdateInstall

@MainActor
enum VisorUpdates {
    /// How often an install waiting for a quiet moment looks again.
    static let quietCheck: Duration = .seconds(30)

    /// At launch, after the server has started: the handler and the install
    /// hook, which win over Shireworks Kit's update sheet; then the kit
    /// started (the build this is written for Shireworks, and crashes
    /// caught), here and not only by the window's `.shireworks()`, as a
    /// menu bar app's window may never open; and, when the server says an
    /// update didn't stay up and was rolled back (its relauncher's word, or
    /// the server agent's watch's), that, once.
    static func start() {
        // A copy staged for an install before is done with: the install
        // relaunched into it, or failed.
        try? FileManager.default.removeItem(at: staging)
        AppUpdates.register(autoUpdate: { _ in .installMyself })
        AppUpdates.register(install: { offer in await install(offer) })
        ShireworksKit.start()
        Task { await reportRollback() }
    }

    /// The last rollback the server said, reported to Shireworks: kept, so
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

    /// The team this process is signed for, from its own entitlements as
    /// the kernel holds them (`com.apple.developer.team-identifier`, or
    /// `com.apple.application-identifier`'s prefix), never a bundle on
    /// disk (as Visor Disk Utility's, #510); nil when it has none (ad hoc).
    static func runningTeam() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        if let team = SecTaskCopyValueForEntitlement(task, "com.apple.developer.team-identifier" as CFString, nil) as? String,
           HandedOverBuild.isTeam(team) {
            return team
        }
        guard let identifier = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String,
              let prefix = identifier.split(separator: ".").first.map(String.init), HandedOverBuild.isTeam(prefix) else { return nil }
        return prefix
    }

    /// Where a handed-over build is copied to be checked and installed:
    /// Visor's own temporary folder (on the Visor volume, emptied at each
    /// start), else this user's.
    static var staging: URL {
        (MacPlaces.folders.temporary ?? FileManager.default.temporaryDirectory).appendingPathComponent("update", isDirectory: true)
    }

    /// The verified build, installed once no session is mid-turn: from its
    /// copy in `staging`, once that has passed its checks (HandedOverBuild).
    static func install(_ offer: UpdateOffer) async {
        guard let bundle = offer.bundle else {
            await AppUpdates.installFailed("Shireworks handed over no build")
            return
        }
        // Until it's known which process serves.
        while LocalServer.shared.mode == .handingOver {
            try? await Task.sleep(for: .seconds(2))
        }
        while await LocalServer.shared.busy() {
            try? await Task.sleep(for: quietCheck)
        }
        // Just before it's installed: copied out of the group's container
        // and checked, or refused, this build staying.
        let checked = HandedOverBuild(run: HandedOverBuild.processes)
        let path: String
        switch await checked.stage(bundle.path, in: staging.path, team: runningTeam()) {
        case .ready(let staged):
            path = staged
        case .refused(let why):
            await AppUpdates.installFailed(why)
            return
        }
        await AppUpdates.installing()
        // Every session that was running is carried on (none is mid-turn).
        if let problem = await LocalServer.shared.install(path) {
            await AppUpdates.installFailed(problem)
        }
    }
}

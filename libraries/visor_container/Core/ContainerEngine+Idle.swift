// The idle stop: once nothing has run in the container and no session has
// been placed in it for the settings' idle minutes, it's stopped, and its
// memory given back (what the guest frees isn't, while it runs). A new image
// is taken at the next start, so it's only ever taken when idle.

import Foundation

extension ContainerEngine {
    /// Looked at each half a minute (serverStarted's loop; the tests call it
    /// with their own clock).
    public func tick() async {
        guard machine != nil, starting == nil else { return }
        let placed = await context.placedSessions()
        guard executions.isEmpty, placed == 0 else {
            idleSince = nil
            return
        }
        let now = context.now()
        guard let idle = idleSince else {
            idleSince = now
            return
        }
        let minutes = max(context.configuration().idleMinutes, 1)
        guard now.timeIntervalSince(idle) >= Double(minutes * 60) else { return }
        await stop(reason: "nothing in it for \(minutes) minute\(minutes == 1 ? "" : "s")")
    }
}

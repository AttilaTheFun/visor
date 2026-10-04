// Ending: a relaunch into another build, the agents stopped before a
// quit.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

extension VisorServer {
    /// Restarts the server, optionally installing `build` over this one
    /// first, and asks the new one to carry on `carrying`. Returns what went
    /// wrong, or nil — on success this process is on its way out. How it
    /// comes back is the platform's: an app is reopened, a command-line
    /// server starts its successor.
    @discardableResult
    public func relaunch(installing build: String?, carrying: [String]) -> String? {
        // The sessions that are mid-turn are written down as such: the flag
        // is what the next launch reads to know a reply is owed.
        for record in sessions where record.info.busy { record.interrupted = true }
        saveArchive()
        // Empty means the default: everything that was running. A caller
        // that names sessions gets exactly those.
        if let problem = ServerPlatform.current.lifecycle.relaunch(installing: build, carrying: carrying.joined(separator: ",")) {
            return problem
        }
        Self.log("relaunching\(build.map { " into \($0)" } ?? "")")
        // Once the answer to whoever asked has gone out.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            quit()
        }
        return nil
    }

    /// Ends every session (the app is quitting). What was running is
    /// written down as running, so the next launch can carry it on: this is
    /// the record of the shutdown, however the app was quit.
    public func endAll() async {
        for record in sessions where record.info.busy { record.interrupted = true }
        saveArchive()
        // What the agents say as they go is not heard: the record of the
        // shutdown is the one just written.
        for record in sessions { record.stopListening() }
        // Waited for, not merely asked: an agent that outlives the app
        // runs on with nobody at the other end of its pipes. All at once:
        // each has its own few seconds to go.
        let ending = sessions.map { record in Task { await record.process.end(within: .seconds(4)) } }
        for task in ending { await task.value }
        agentsEnded = true
    }

    /// Ends the agents, then the app. The way to quit from the app's own
    /// code: the agents are gone before the app is asked to terminate, so
    /// it has nothing to wait for then.
    public func quit() {
        Task {
            await endAll()
            ServerPlatform.current.lifecycle.terminate()
        }
    }
}

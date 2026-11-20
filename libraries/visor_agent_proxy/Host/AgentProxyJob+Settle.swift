// The job made to match settings.json and this app, as `decide` says: at
// the server's start, on a Mac (Visor's own: VisorMacApp, or `Visor
// --server`, which folds it in). launchctl is asked off the main thread.

#if os(macOS)
import Foundation
import VisorLaunchAgent
import VisorServer

extension AgentProxyJob {
    /// The job settled for the app this process is, its data in `places`.
    /// `folded`: agent-proxy runs inside the server (the server agent), so
    /// the job is stopped and removed whatever the settings say.
    public static func settle(bundleID: String, version: String, places: AgentProxyHost.Places, folded: Bool = false,
                              log: @escaping @Sendable (String) -> Void) async {
        let configured: Bool?
        let settings: AgentProxySettings?
        do {
            settings = try AgentProxyHost.configured(at: places.settingsFile)
            configured = folded ? false : settings != nil
        } catch {
            settings = nil
            configured = folded ? false : nil
        }
        await job(bundleID: bundleID).settle(configured: configured, version: version, settings: AgentProxyHost.digest(settings),
                                             why: folded ? "it runs inside the server agent now" : "settings.json has no agentProxy",
                                             log: log)
    }
}
#endif

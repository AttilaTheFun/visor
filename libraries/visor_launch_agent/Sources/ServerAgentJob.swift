// The server as a background agent on a Mac (docs/DEVELOPMENT.md, The
// server as a background agent): `Visor --server`, Visor.app's own
// executable run headless by this user's launchd, so it has the app's
// signature, keychain items and entitlements, starts at login whether or not
// the app is open, and is started again if it fails. Visor.app is then its
// client. One of Visor's LaunchAgents (LaunchAgentJob), settled by the app
// at its launch (ServerHandOver), and only while the app's `ServerAsAgent`
// default is on: off (the default), the server runs in the app, as before.
//
// - `<bundle id>.server` (`com.LoganShire.Visor.server`), its plist in
//   ~/Library/LaunchAgents, its log `~/Library/Logs/Visor-server.log`.
// - KeepAlive after a failure only: an exit of 0 is the server asked to
//   stop (`/api/quit`), or making way for its update, which its watcher
//   starts (ServerAgentRestart).
// - AbandonProcessGroup: the agents' hosts and the update's watcher are
//   its children, and outlive it.

import Foundation

public enum ServerAgentJob {
    /// The app's argument that makes it the server agent.
    public static let argument = "--server"
    /// The app's default (`defaults write com.LoganShire.Visor
    /// ServerAsAgent -bool true`) that has the server run as the agent.
    public static let defaultsKey = "ServerAsAgent"

    /// `<bundle id>.server`.
    public static func label(bundleID: String) -> String { bundleID + ".server" }
    /// `~/Library/Logs/Visor-server.log`.
    public static func logPath(home: String = NSHomeDirectory()) -> String { "\(home)/Library/Logs/Visor-server.log" }

    /// The job for the app with `bundleID`.
    public static func job(bundleID: String, home: String = NSHomeDirectory()) -> LaunchAgentJob {
        LaunchAgentJob(label: label(bundleID: bundleID), argument: argument, name: "the server agent", log: logPath(home: home),
                       abandonsProcessGroup: true, home: home)
    }
}

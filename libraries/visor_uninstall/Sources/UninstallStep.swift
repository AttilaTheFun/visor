// One thing Uninstall… does, says it will do in its dry run, or only says.

import DiskVolumes

public struct UninstallStep: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// The app quit, if it runs (Visor.app: its server in the app ends
        /// its agents first, as Quit Visor does).
        case quit(bundleID: String)
        /// The server agent stopped and unregistered from SMAppService
        /// (`<app>/Contents/MacOS/Visor server-agent unregister`): out of
        /// launchd and Background Items.
        case unregisterServerAgent(executable: String)
        /// A job of this user's launchd stopped, and its plist removed.
        case removeLaunchAgent(label: String, plist: String)
        /// The agents' hosts still running (`visor-agent-host` in the app's
        /// Helpers) ended, and their agents with them.
        case endAgentHosts(program: String)
        /// A keychain service's generic passwords deleted: in the login
        /// keychain, or (`accessGroup`) the data-protection keychain.
        case deleteKeychainItems(service: String, accessGroup: String?, accounts: [String])
        /// A defaults domain deleted (`defaults delete <domain>`).
        case deleteDefaults(domain: String)
        /// The app's privacy permissions reset (`tccutil reset All <id>`).
        case resetPrivacy(bundleID: String)
        /// The lines Visor added to an authorized_keys file taken out.
        case removeKeyLines(file: String, lines: [String])
        /// A file or folder removed.
        case remove(path: String)
        /// Said only: never removed (Claude Code's own project folders).
        case list(path: String)
        /// Said only: a volume of Visor's left as it is, its deletion not
        /// asked for.
        case keep(path: String)
        /// One of Visor's volumes deleted, by its APFS volume UUID
        /// (diskutil, as an administrator; VolumeGuard with it asked for).
        case deleteVolume(role: VolumeRole, uuid: String)
        /// A volume a conversion kept (`Sessions-old-ci`, `Sessions-cs-failed`)
        /// deleted, by its APFS volume UUID, with the volumes.
        case deleteKept(name: String, uuid: String)
        /// Moved to the Trash (the apps, last).
        case trash(path: String)
        /// Said only: what a person undoes by hand, never run.
        case note(String)
    }

    /// When it comes: the dry run lists them in this order, and the
    /// uninstall does them in it.
    public enum Stage: Int, Comparable, Sendable {
        /// Stopped and removed.
        case remove
        /// Listed, never removed.
        case list
        /// Visor's volume kept, its deletion not asked for: a line of its own.
        case kept
        /// The volumes, only when their deletion is asked for.
        case volumes
        /// The apps to the Trash.
        case trash
        /// Printed: by hand, if at all.
        case note

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var action: Action
    public var stage: Stage
    /// What it is, in a line, for the dry run.
    public var what: String

    public init(_ action: Action, stage: Stage, what: String) {
        self.action = action
        self.stage = stage
        self.what = what
    }

    /// Whether running it changes anything (the lists and notes don't).
    public var changes: Bool { stage != .list && stage != .kept && stage != .note }
}

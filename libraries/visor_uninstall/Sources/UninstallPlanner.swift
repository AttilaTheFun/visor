// Uninstall…'s plan made from what's there (docs/containers.md, Visor's
// volumes: a Mac used with Visor and its containers, uninstalled, and its
// three volumes deleted, is as it was). Each step is planned only for what
// is found, so the dry run lists exactly what would go:
//
// - Visor.app quit; the server agent stopped and unregistered
//   (SMAppService), 0.64's plist and agent-proxy's job and plist removed;
//   the agents' hosts still running ended.
// - Both keychain services' items: the server's (`<id>.server`) and the
//   client's (`<id>`), in the login keychain and, under the app's access
//   group (which Visor Disk Utility is signed with too), the
//   data-protection keychain, where the app key is.
// - The defaults domains (Visor's and Visor Disk Utility's) and their
//   Saved State; the privacy permissions (`tccutil reset All <id>`).
// - The lines Visor added to ~/.ssh/authorized_keys (`visor:<device>`,
//   and 0.64's `visor`), never one added by hand.
// - `~/.visor`, and what's left in the home folder of before the Visor
//   volume: Application Support's `Visor` and `<id>`, `~/Library/Logs/
//   Visor-*`, the system's Caches and HTTPStorages for both apps, and
//   /tmp/visor-relaunch.log.
// - Listed, never removed: the Claude Code project folders of sessions on
//   the Sessions volume (`~/.claude/projects/-Volumes-Sessions-…`), which
//   Move Back left in this Mac's Claude Code.
// - Only when asked, with the volumes' names typed: the three volumes,
//   by their APFS volume UUIDs.
// - Last: Visor.app and Visor Disk Utility to the Trash.
// - Printed, never run: how to undo a `tailscale serve` of port 7433 and
//   a `.zshrc` export of the admin token, if they were done by hand.

import DiskVolumes
import Foundation

public struct UninstallPlanner: Sendable {
    /// Visor.app's bundle id, and Visor Disk Utility's.
    public var bundleID: String
    public var diskUtilityID: String
    /// This user's home folder.
    public var home: String
    /// Visor.app and Visor Disk Utility, where they are.
    public var app: String
    public var diskUtility: String
    /// Visor's keychain access group (`<team>.<bundle id>`), when this
    /// process is signed with it; nil: the data-protection keychain's items
    /// can't be reached (a build signed ad hoc), and the plan says so.
    public var accessGroup: String?
    /// The volumes found, to delete when `deleteVolumes` (Visor's own
    /// alone: named for their roles, with UUIDs).
    public var volumes: [VolumeState]
    public var deleteVolumes: Bool

    public init(bundleID: String = "com.LoganShire.Visor", diskUtilityID: String = "com.LoganShire.Visor.DiskUtility", home: String,
                app: String = "/Applications/Visor.app", diskUtility: String = "/Applications/Visor Disk Utility.app",
                accessGroup: String?, volumes: [VolumeState] = [], deleteVolumes: Bool = false) {
        self.bundleID = bundleID
        self.diskUtilityID = diskUtilityID
        self.home = home
        self.app = app
        self.diskUtility = diskUtility
        self.accessGroup = accessGroup
        self.volumes = volumes
        self.deleteVolumes = deleteVolumes
    }

    /// The comment a line Visor added to authorized_keys ends in
    /// (VisorServer.keyTag).
    public static let keyTag = "visor:"
    /// The port `tailscale serve` was pointed at by hand, if it was.
    public static let port = 7433

    /// The plan, from what `files` and `keychain` say is there.
    public func plan(files: some UninstallFiles, keychain: some UninstallKeychain) -> UninstallPlan {
        var steps: [UninstallStep] = []
        func remove(_ action: UninstallStep.Action, _ what: String) { steps.append(UninstallStep(action, stage: .remove, what: what)) }
        let library = home + "/Library"

        // The apps and the server.
        remove(.quit(bundleID: bundleID), "Visor quit, if it's open (the server in it ends its agents first)")
        let executable = app + "/Contents/MacOS/Visor"
        if files.exists(executable) {
            remove(.unregisterServerAgent(executable: executable),
                   "the server agent (\(bundleID).server) stopped and unregistered: out of launchd and Background Items")
        }
        for name in ["server", "agent-proxy"] {
            let label = "\(bundleID).\(name)"
            let plist = "\(library)/LaunchAgents/\(label).plist"
            if files.exists(plist) { remove(.removeLaunchAgent(label: label, plist: plist), "\(label) stopped, and \(plist) removed") }
        }
        let hosts = app + "/Contents/Helpers/visor-agent-host"
        remove(.endAgentHosts(program: hosts), "the agents' hosts still running (\(hosts)) ended, with their agents")

        // The keychain.
        for service in [bundleID + ".server", bundleID] {
            let login = keychain.accounts(service: service, accessGroup: nil)
            if !login.isEmpty {
                remove(.deleteKeychainItems(service: service, accessGroup: nil, accounts: login),
                       "the login keychain's \(service) items: \(login.joined(separator: ", "))")
            }
            if let accessGroup {
                let protected = keychain.accounts(service: service, accessGroup: accessGroup)
                if !protected.isEmpty {
                    remove(.deleteKeychainItems(service: service, accessGroup: accessGroup, accounts: protected),
                           "the data-protection keychain's \(service) items (Visor's access group): \(protected.joined(separator: ", "))")
                }
            }
        }

        // Defaults, Saved State and privacy.
        for domain in [bundleID, diskUtilityID] {
            if files.exists("\(library)/Preferences/\(domain).plist") {
                remove(.deleteDefaults(domain: domain), "the defaults of \(domain) (defaults delete \(domain))")
            }
            let state = "\(library)/Saved Application State/\(domain).savedState"
            if files.exists(state) { remove(.remove(path: state), state) }
        }
        remove(.resetPrivacy(bundleID: bundleID), "Visor's privacy permissions reset (tccutil reset All \(bundleID))")

        // SSH: the lines Visor added.
        let keys = home + "/.ssh/authorized_keys"
        let lines = (files.text(keys) ?? "").split(separator: "\n").map(String.init).filter(Self.isVisorsKeyLine)
        if !lines.isEmpty {
            let devices = lines.compactMap { $0.split(separator: " ").last.map(String.init) }
            remove(.removeKeyLines(file: keys, lines: lines), "\(keys): Visor's lines (\(devices.joined(separator: ", ")))")
        }

        // What's left in the home folder.
        var leftovers = [home + "/.visor", "\(library)/Application Support/Visor", "\(library)/Application Support/\(bundleID)",
                         "/tmp/visor-relaunch.log"]
        for id in [bundleID, diskUtilityID] {
            leftovers += ["\(library)/Caches/\(id)", "\(library)/HTTPStorages/\(id)", "\(library)/HTTPStorages/\(id).binarycookies"]
        }
        leftovers += files.contents(ofFolder: "\(library)/Logs").filter { $0.hasPrefix("Visor-") }.sorted().map { "\(library)/Logs/\($0)" }
        for path in leftovers where files.exists(path) { remove(.remove(path: path), path) }

        // Listed only: Claude Code's project folders of sessions on Sessions.
        let projects = home + "/.claude/projects"
        let key = Self.projectKey(of: VolumeRole.sessions.mountPoint)
        for name in files.contents(ofFolder: projects).sorted() where name == key || name.hasPrefix(key + "-") {
            steps.append(UninstallStep(.list(path: "\(projects)/\(name)"), stage: .list, what: "\(projects)/\(name)"))
        }

        // The volumes, when asked: Visor's own alone. Not asked, the Visor
        // volume is said to be kept, so it's clear nothing on it is touched.
        let visor = VolumeRole.visor.mountPoint
        if !deleteVolumes, files.exists(visor) {
            steps.append(UninstallStep(.keep(path: visor), stage: .kept,
                                       what: "Kept: \(visor) (Visor's data, containers, logs): removed with --delete-volumes"))
        }
        if deleteVolumes {
            for state in volumes {
                guard let volume = state.volume, volume.name == state.role.volumeName, volume.roles.isEmpty,
                      DiskCommand.isVolumeUUID(volume.uuid) else { continue }
                steps.append(UninstallStep(.deleteVolume(role: state.role, uuid: volume.uuid), stage: .volumes,
                                           what: "\(state.role.volumeName) (\(volume.device), \(volume.uuid)), at \(state.path)"))
            }
        }

        // Last, the apps.
        for path in [app, diskUtility] where files.exists(path) {
            steps.append(UninstallStep(.trash(path: path), stage: .trash, what: path))
        }

        // By hand, if at all.
        steps.append(UninstallStep(.note(Self.tailscaleNote), stage: .note, what: Self.tailscaleNote))
        if let line = Self.adminTokenExport(in: files.text(home + "/.zshrc")) {
            let note = "~/.zshrc line \(line) exports VISOR_ADMIN_TOKEN: delete that line (`Visor admin-token` prints it for a script, "
                + "while Visor is installed)."
            steps.append(UninstallStep(.note(note), stage: .note, what: note))
        }
        if accessGroup == nil {
            let note = "This Visor Disk Utility isn't signed with Visor's keychain access group, so the data-protection keychain's items "
                + "(the app key) can't be reached: run a Developer ID build of it, or delete them in Keychain Access."
            steps.append(UninstallStep(.note(note), stage: .note, what: note))
        }
        return UninstallPlan(steps: steps)
    }

    /// What to run to undo a `tailscale serve` of Visor's port.
    public static let tailscaleNote = "If you ran `tailscale serve` for Visor's port \(port), see it with `tailscale serve status` and turn it off "
        + "with the same command ending in `off` (for example `tailscale serve --bg --https=443 off`). Uninstall… never runs tailscale."

    /// Whether an authorized_keys line is one Visor added: its comment
    /// `visor:<device>`, or 0.64's `visor`.
    public static func isVisorsKeyLine(_ line: String) -> Bool {
        let words = line.split(separator: " ")
        guard words.count >= 3, let last = words.last else { return false }
        return last.hasPrefix(keyTag) || (words.count == 3 && last == "visor")
    }

    /// Claude Code's project folder name for a path: each `/` and `.` a `-`.
    public static func projectKey(of path: String) -> String {
        String(path.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    /// The line (from 1) of a `.zshrc` that exports VISOR_ADMIN_TOKEN, if
    /// one does. Only the number: the line holds the token.
    public static func adminTokenExport(in text: String?) -> Int? {
        guard let text else { return nil }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let words = line.trimmingCharacters(in: .whitespaces)
            if words.hasPrefix("export VISOR_ADMIN_TOKEN=") || words.hasPrefix("VISOR_ADMIN_TOKEN=") { return index + 1 }
        }
        return nil
    }
}

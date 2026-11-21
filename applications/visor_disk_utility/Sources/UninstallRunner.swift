// Uninstall… run: its plan's steps done in order (UninstallPlanner made
// them, and the dry run listed them), each said as it's done, and a step
// that fails said and passed over, so the rest still goes. The volumes, when
// their deletion was asked for and their names typed, are deleted together
// through the administrator prompt, VolumeGuard letting those roles alone
// through. Every call blocks: the app makes them off the main actor.

import AppKit
import DiskVolumes
import Foundation
import VisorUninstall

enum UninstallRunner {
    /// The plan for this Mac now: the disks surveyed for the volumes when
    /// their deletion is asked for.
    static func plan(deleteVolumes: Bool) throws -> UninstallPlan {
        let volumes = deleteVolumes ? try DiskTool.survey() : nil
        let planner = UninstallPlanner(home: NSHomeDirectory(), app: installed("Visor.app"), diskUtility: ownBundle,
                                       accessGroup: MacUninstallKeychain.ownAccessGroup(bundleID: visorID),
                                       volumes: volumes.map { survey in VolumeRole.allCases.map { survey.state(for: $0) } } ?? [],
                                       deleteVolumes: deleteVolumes)
        return planner.plan(files: MacUninstallFiles(), keychain: MacUninstallKeychain())
    }

    static let visorID = "com.LoganShire.Visor"

    /// This app's bundle, wherever it is.
    static var ownBundle: String { Bundle.main.bundlePath }

    /// An app of Visor's in /Applications.
    static func installed(_ name: String) -> String { "/Applications/" + name }

    /// Runs the plan: `typed`, the volumes' names as the person typed them
    /// (UninstallConfirmation), or their steps are passed over. `say` is
    /// told each step's outcome, a line each.
    static func run(_ plan: UninstallPlan, typed: String?, route: PrivilegeRoute, say: (String) -> Void) {
        // The volumes together, once, where their stage comes.
        var volumesDone = plan.volumes.isEmpty
        for step in plan.steps {
            if step.stage >= .volumes, !volumesDone {
                deleteVolumes(plan, typed: typed, route: route, say: say)
                volumesDone = true
            }
            guard step.changes, step.stage != .volumes else { continue }
            do {
                try perform(step.action)
                say("done: " + step.what)
            } catch {
                say("not done: \(step.what): \(error.localizedDescription)")
            }
        }
    }

    /// The volumes deleted, if their names were typed.
    private static func deleteVolumes(_ plan: UninstallPlan, typed: String?, route: PrivilegeRoute, say: (String) -> Void) {
        let roles = plan.volumes
        guard let typed, UninstallConfirmation.matches(typed, roles: roles) else {
            say("not done: the volumes weren't deleted: \"\(UninstallConfirmation.phrase(for: roles))\" wasn't typed")
            return
        }
        let commands = plan.steps(.volumes).compactMap { step -> DiskCommand? in
            guard case let .deleteVolume(role, uuid) = step.action else { return nil }
            return try? DiskCommand.deleteVolume(role, uuid: uuid)
        }
        do {
            _ = try DiskTool.change(commands, route: route, deleting: Set(roles))
            say("done: deleted " + roles.map(\.volumeName).joined(separator: ", "))
        } catch DiskVolumesError.cancelled {
            say("not done: the volumes weren't deleted (the administrator prompt was cancelled)")
        } catch {
            say("not done: the volumes weren't deleted: \(error)")
        }
    }

    private static func perform(_ action: UninstallStep.Action) throws {
        let files = FileManager.default
        switch action {
        case let .quit(bundleID):
            quit(bundleID)
        case let .unregisterServerAgent(executable):
            _ = try DiskTool.run([executable, "server-agent", "unregister"])
        case let .removeLaunchAgent(label, plist):
            _ = try? DiskTool.run(["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"])
            if files.fileExists(atPath: plist) { try files.removeItem(atPath: plist) }
        case let .endAgentHosts(program):
            // pkill's 1 is "none was running".
            _ = try? DiskTool.run(["/usr/bin/pkill", "-TERM", "-f", program])
        case let .deleteKeychainItems(service, accessGroup, accounts):
            let failed = MacUninstallKeychain().delete(service: service, accessGroup: accessGroup, accounts: accounts)
            if !failed.isEmpty { throw DiskVolumesError.failed(failed.joined(separator: "; ")) }
        case let .deleteDefaults(domain):
            _ = try DiskTool.run(["/usr/bin/defaults", "delete", domain])
        case let .resetPrivacy(bundleID):
            _ = try DiskTool.run(["/usr/bin/tccutil", "reset", "All", bundleID])
        case let .removeKeyLines(file, lines):
            try removeLines(lines, from: file)
        case let .remove(path):
            try files.removeItem(atPath: path)
        case let .trash(path):
            try files.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        case .list, .note, .deleteVolume:
            break
        }
    }

    /// The app quit, if it runs, and waited for (a minute, then forced).
    private static func quit(_ bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.forEach { $0.terminate() }
        for _ in 0..<120 where running.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.5) }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// `lines` taken out of `file`, every other line kept as it was, and
    /// the file's mode with it.
    private static func removeLines(_ lines: [String], from file: String) throws {
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let drop = Set(lines)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !drop.contains(String($0)) }
        let mode = (try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions]
        try kept.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file) }
    }

    /// What's left of this app's own once it's run (the window, quitting,
    /// writes them again): its defaults and Saved State, removed just
    /// before it ends.
    static func forgetOwn() {
        let id = Bundle.main.bundleIdentifier ?? "com.LoganShire.Visor.DiskUtility"
        _ = try? DiskTool.run(["/usr/bin/defaults", "delete", id])
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Saved Application State/\(id).savedState")
    }
}

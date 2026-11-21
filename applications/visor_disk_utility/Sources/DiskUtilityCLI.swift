// The app's command line: the same survey, plan, guard and commands as its
// window, for a script or a test machine.

import DiskVolumes
import Foundation
import VisorUninstall

/// `Visor Disk Utility status`, `… create sessions|sources|visor`, `…
/// erase-containers --yes` (the container's folder on Visor emptied);
/// options `--reserve-gb <n>`, `--quota-gb <n>` (the role's defaults
/// otherwise) and `--sudo` (`sudo -n` instead of the administrator prompt).
/// `… exclude-visor`: Spotlight turned off on the Visor volume where it's
/// found indexing (Time Machine's exclusion is the person's: it says how).
/// Each writes volumes.json after.
///
/// `… uninstall`: Uninstall…'s dry run, printed, and nothing done; `…
/// uninstall --yes` does it (UninstallRunner), the apps moved to the Trash
/// last; with `--delete-volumes`, the three volumes too, once their names
/// are typed on standard input as the dry run asks (or given with
/// `--confirm "<that>"`).
enum DiskUtilityCLI {
    static let verbs: Set<String> = ["status", "create", "erase-containers", "exclude-visor", "uninstall"]

    /// Runs and exits when the arguments are a command; else returns, for
    /// the app.
    static func handle(_ arguments: [String]) {
        guard arguments.count > 1, verbs.contains(arguments[1]) else { return }
        do {
            try run(Array(arguments.dropFirst()))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("visor-disk-utility: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        let route: PrivilegeRoute = arguments.contains("--sudo") ? .sudo : .administratorPrompt
        if arguments[0] == "uninstall" { return try uninstall(arguments, route: route) }
        var survey = try DiskTool.survey()
        switch arguments[0] {
        case "create":
            guard arguments.count > 1, let role = VolumeRole(rawValue: arguments[1]) else {
                throw DiskVolumesError.blocked("create sessions|sources|visor")
            }
            let commands = try survey.state(for: role).createCommands(
                reserve: try size(arguments, "--reserve-gb") ?? role.defaultReserve,
                quota: try size(arguments, "--quota-gb") ?? role.defaultQuota)
            commands.forEach { print("running: \($0)") }
            survey = try DiskTool.change(commands, route: route)
        case "exclude-visor":
            let commands = try survey.state(for: .visor).exclusionCommands(DiskTool.exclusions())
            commands.forEach { print("running: \($0)") }
            if !commands.isEmpty { survey = try DiskTool.change(commands, route: route) }
        case "erase-containers":
            guard arguments.contains("--yes") else {
                throw DiskVolumesError.blocked("erase-containers deletes the container's image, root filesystem, caches and logs: add --yes.")
            }
            print(try DiskTool.clearContainers().map { "emptied \($0)" } ?? "the container's folder was empty already")
        default:
            break
        }
        for role in VolumeRole.allCases { print(describe(survey.state(for: role))) }
        if survey.state(for: .visor).isMountedInPlace {
            let exclusions = DiskTool.exclusions()
            print("Visor: \(exclusions.summary)")
            if exclusions.timeMachineExcluded == false {
                print("  note: leave it out in System Settings › General › Time Machine › Options… › + › Visor (no app may: macOS 27)")
            }
        }
        print("wrote \(try DiskTool.writeStatus(survey).path)")
    }

    /// Uninstall…: the dry run, then, with `--yes`, the plan run.
    private static func uninstall(_ arguments: [String], route: PrivilegeRoute) throws {
        let plan = try UninstallRunner.plan(deleteVolumes: arguments.contains("--delete-volumes"))
        print(plan.dryRun)
        guard arguments.contains("--yes") else {
            print("\nA dry run: nothing was done. Run again with --yes to uninstall.")
            return
        }
        var typed: String?
        if !plan.volumes.isEmpty {
            let phrase = UninstallConfirmation.phrase(for: plan.volumes)
            if let index = arguments.firstIndex(of: "--confirm"), index + 1 < arguments.count {
                typed = arguments[index + 1]
            } else {
                print("\nEverything on those volumes is deleted. Type \"\(phrase)\" to delete them, or anything else to keep them:")
                typed = readLine()
            }
        }
        UninstallRunner.run(plan, typed: typed, route: route) { print($0) }
        UninstallRunner.forgetOwn()
    }

    /// `--name <gigabytes>` in bytes; nil when it isn't given.
    private static func size(_ arguments: [String], _ name: String) throws -> Int64? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard index + 1 < arguments.count, let bytes = ByteSize.gigabytes(arguments[index + 1]) else {
            throw DiskVolumesError.blocked("\(name) takes a size in gigabytes.")
        }
        return bytes
    }

    private static func describe(_ state: VolumeState) -> String {
        let plan = switch state.plan {
        case .adopt: "adopt \(state.volume?.device ?? "")"
        case let .create(container): "create in \(container)"
        case let .blocked(why): "blocked: \(why)"
        }
        var lines = ["\(state.role.volumeName): \(plan)",
                     "  path \(state.path), format \(state.format)"
                         + (state.isCaseSensitive == false ? " (case-insensitive)" : "")]
        if let volume = state.volume {
            lines.append("  used \(state.usedDescription ?? ""), available \(state.available.map(ByteSize.describe) ?? "?"), "
                + "reserve \(volume.reserve > 0 ? ByteSize.describe(volume.reserve) : "none"), "
                + "quota \(volume.quota > 0 ? ByteSize.describe(volume.quota) : "none")")
        }
        lines += state.notes.map { "  note: \($0)" }
        return lines.joined(separator: "\n")
    }
}

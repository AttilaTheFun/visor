// The app's command line: the same survey, plan, guard and commands as its
// window, for a script or a test machine.

import DiskVolumes
import Foundation

/// `Visor Disk Utility status`, `… create sessions|containers`, `…
/// erase-containers --yes`; options `--reserve-gb <n>`, `--quota-gb <n>`
/// (the role's defaults otherwise) and `--sudo` (`sudo -n` instead of the
/// administrator prompt). Each writes volumes.json after.
enum DiskUtilityCLI {
    static let verbs: Set<String> = ["status", "create", "erase-containers"]

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
        var survey = try DiskTool.survey()
        switch arguments[0] {
        case "create":
            guard arguments.count > 1, let role = VolumeRole(rawValue: arguments[1]) else {
                throw DiskVolumesError.blocked("create sessions|containers")
            }
            let commands = try survey.state(for: role).createCommands(
                reserve: try size(arguments, "--reserve-gb") ?? role.defaultReserve,
                quota: try size(arguments, "--quota-gb") ?? role.defaultQuota)
            commands.forEach { print("running: \($0)") }
            survey = try DiskTool.change(commands, route: route)
        case "erase-containers":
            guard arguments.contains("--yes") else { throw DiskVolumesError.blocked("erase-containers erases everything on Containers: add --yes.") }
            let role = VolumeRole.containers
            let state = survey.state(for: role)
            let commands = try state.eraseCommands(
                reserve: try size(arguments, "--reserve-gb") ?? state.volume?.reserve ?? role.defaultReserve,
                quota: try size(arguments, "--quota-gb") ?? state.volume?.quota ?? role.defaultQuota)
            commands.forEach { print("running: \($0)") }
            survey = try DiskTool.change(commands, route: route)
        default:
            break
        }
        for role in VolumeRole.allCases { print(describe(survey.state(for: role))) }
        print("wrote \(try DiskTool.writeStatus(survey).path)")
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

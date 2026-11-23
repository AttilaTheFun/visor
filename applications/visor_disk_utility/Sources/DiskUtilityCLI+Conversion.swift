// The command line's conversion of a case-insensitive Sessions or Sources
// (docs/volume-conversion.md), a small method a verb: the same DiskTool
// steps as the window's Stage, Swap In and Delete….

import DiskVolumes
import Foundation

extension DiskUtilityCLI {
    static let conversionVerbs: Set<String> = ["stage", "copy-staged", "swap", "unswap", "delete-kept", ConversionPlanner.checkVerb]

    /// Runs a conversion verb; the disks after.
    static func convert(_ arguments: [String], route: PrivilegeRoute) throws -> DiskSurvey {
        switch arguments[0] {
        case "stage": return try stage(roles(arguments), route: route)
        case "copy-staged": return try copyStaged(roles(arguments), replace: arguments.contains("--replace"))
        case "swap": return try swap(roles(arguments), route: route)
        case "unswap": return try unswap(roles(arguments), route: route)
        default: return try deleteKept(arguments, route: route)
        }
    }

    /// The roles named after the verb: `sessions`, `sources` or `both`.
    private static func roles(_ arguments: [String]) throws -> [VolumeRole] {
        guard arguments.count > 1, let roles = VolumeRole.conversionRoles(arguments[1]) else {
            throw DiskVolumesError.blocked("\(arguments[0]) sessions|sources|both")
        }
        return roles
    }

    private static func stage(_ roles: [VolumeRole], route: PrivilegeRoute) throws -> DiskSurvey {
        let disks = try DiskTool.survey()
        for role in roles {
            try ConversionPlanner.stageCommands(role, in: disks, user: DiskTool.user).forEach { print("planned: \($0)") }
        }
        let after = try DiskTool.stage(roles, route: route)
        roles.forEach { print("staged \($0.stagedName) at \($0.stagedMountPoint): next, copy-staged \($0.rawValue) (as \(DiskTool.user), no sudo)") }
        return after
    }

    private static func copyStaged(_ roles: [VolumeRole], replace: Bool) throws -> DiskSurvey {
        for role in roles {
            let marker = try DiskTool.copyStaged(role, replace: replace) { print($0) }
            print("\(role.stagedName) \(marker.summary): Swap In within two hours.")
        }
        return try DiskTool.survey()
    }

    private static func swap(_ roles: [VolumeRole], route: PrivilegeRoute) throws -> DiskSurvey {
        let disks = try DiskTool.survey()
        for role in roles {
            let marker = try DiskTool.marker(for: role)
            try ConversionPlanner.swapCommands(role, in: disks, marker: marker, now: Date()).forEach { print("planned: \($0)") }
        }
        let after = try DiskTool.swap(roles, route: route)
        DiskTool.swapResult(roles, in: after).forEach { print("swapped: \($0)") }
        return after
    }

    private static func unswap(_ roles: [VolumeRole], route: PrivilegeRoute) throws -> DiskSurvey {
        let disks = try DiskTool.survey()
        for role in roles { try ConversionPlanner.unswapCommands(role, in: disks).forEach { print("planned: \($0)") } }
        let after = try DiskTool.unswap(roles, route: route)
        for role in roles {
            let state = after.state(for: role)
            print("unswapped: \(role.volumeName) is \(state.format) at \(state.path) again; the converted copy is \(role.failedName), unmounted.")
        }
        return after
    }

    /// `delete-kept <name> --confirm "delete <name>"`, or the phrase typed
    /// on standard input.
    private static func deleteKept(_ arguments: [String], route: PrivilegeRoute) throws -> DiskSurvey {
        guard arguments.count > 1, !arguments[1].hasPrefix("-") else {
            throw DiskVolumesError.blocked("delete-kept <Sessions-old-ci|Sources-old-ci|Sessions-cs-failed|Sources-cs-failed> --confirm \"delete <name>\"")
        }
        let name = arguments[1]
        var typed: String?
        if let index = arguments.firstIndex(of: "--confirm"), index + 1 < arguments.count {
            typed = arguments[index + 1]
        } else {
            print("Everything on \(name) is deleted. Type \"delete \(name)\" to delete it, or anything else to keep it:")
            typed = readLine()
        }
        let after = try DiskTool.deleteKept(name, typed: typed ?? "", route: route)
        print("deleted \(name)")
        return after
    }
}

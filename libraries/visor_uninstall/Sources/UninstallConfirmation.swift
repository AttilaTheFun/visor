// The typed confirmation the volumes' deletion takes: their names, as the
// dry run says them, typed out.

import DiskVolumes
import Foundation

public enum UninstallConfirmation {
    /// What's typed to delete `roles`' volumes, and the volumes a
    /// conversion kept (`kept`, by name: after a swap that stopped
    /// part-way, `Sessions-old-ci` may be the only original): "delete
    /// Sessions, Sources, Visor and Sessions-old-ci".
    public static func phrase(for roles: [VolumeRole], kept: [String] = []) -> String {
        let names = roles.map(\.volumeName) + kept
        let listed: String
        switch names.count {
        case 0: listed = ""
        case 1: listed = names[0]
        default: listed = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "delete " + listed
    }

    /// Whether `typed` is the phrase (its spaces at either end aside): of
    /// the exact case, as a person reads it off the screen.
    public static func matches(_ typed: String, roles: [VolumeRole], kept: [String] = []) -> Bool {
        !(roles.isEmpty && kept.isEmpty) && typed.trimmingCharacters(in: .whitespacesAndNewlines) == phrase(for: roles, kept: kept)
    }
}

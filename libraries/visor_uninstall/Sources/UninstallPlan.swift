// Uninstall…'s plan: every step, in order, and its dry run as text.

import DiskVolumes

public struct UninstallPlan: Equatable, Sendable {
    public var steps: [UninstallStep]

    public init(steps: [UninstallStep]) {
        self.steps = steps.enumerated().sorted { ($0.element.stage, $0.offset) < ($1.element.stage, $1.offset) }.map(\.element)
    }

    /// The steps of a stage.
    public func steps(_ stage: UninstallStep.Stage) -> [UninstallStep] { steps.filter { $0.stage == stage } }

    /// The volumes it would delete.
    public var volumes: [VolumeRole] {
        steps.compactMap { if case let .deleteVolume(role, _) = $0.action { role } else { nil } }
    }

    /// The volumes a conversion kept that it would delete, by name.
    public var keptVolumes: [String] {
        steps.compactMap { if case let .deleteKept(name, _) = $0.action { name } else { nil } }
    }

    /// What's typed to delete them all; nil when it deletes none.
    public var phrase: String? {
        volumes.isEmpty && keptVolumes.isEmpty ? nil : UninstallConfirmation.phrase(for: volumes, kept: keptVolumes)
    }

    /// Whether `typed` is that phrase.
    public func confirms(_ typed: String) -> Bool { UninstallConfirmation.matches(typed, roles: volumes, kept: keptVolumes) }

    /// The dry run: what it removes, what it only lists, the volumes, the
    /// apps, and what's for a person to undo by hand.
    public var dryRun: String {
        let headings: [(UninstallStep.Stage, String)] = [
            (.remove, "Stopped and removed:"),
            (.list, "Listed, not removed (Claude Code's own, kept for you):"),
            (.volumes, "Deleted, as you asked (everything on them):"),
            (.trash, "Moved to the Trash, last:"),
            (.note, "Not done by Uninstall…, if you did them by hand:"),
        ]
        var lines: [String] = []
        for (stage, heading) in headings {
            // Kept: a line each, no heading ("Kept: /Volumes/Visor …").
            if stage == .volumes {
                for step in steps(.kept) {
                    if !lines.isEmpty { lines.append("") }
                    lines.append(step.what)
                }
            }
            let those = steps(stage)
            guard !those.isEmpty else { continue }
            if !lines.isEmpty { lines.append("") }
            lines.append(heading)
            lines += those.map { "  - " + $0.what }
        }
        return lines.joined(separator: "\n")
    }
}

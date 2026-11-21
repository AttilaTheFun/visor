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
            let those = steps(stage)
            guard !those.isEmpty else { continue }
            if !lines.isEmpty { lines.append("") }
            lines.append(heading)
            lines += those.map { "  - " + $0.what }
        }
        return lines.joined(separator: "\n")
    }
}

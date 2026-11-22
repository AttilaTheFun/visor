// Uninstall…'s sheet's state: the dry run, whether the volumes go too and
// their names as typed, and what was done.

import DiskVolumes
import Foundation
import Observation
import VisorUninstall

@MainActor @Observable
final class UninstallModel: Identifiable {
    /// The plan as last made: the dry run shown.
    private(set) var plan: UninstallPlan?
    /// Whether the three volumes are deleted too.
    var deleteVolumes = false
    /// Their names, as the person types them (UninstallConfirmation).
    var typed = ""
    private(set) var isBusy = false
    /// What was done, a line a step, once it's run.
    private(set) var done: [String] = []
    private(set) var failure: String?

    /// The phrase to type for the volumes the plan would delete.
    var phrase: String? {
        guard let plan, !plan.volumes.isEmpty else { return nil }
        return UninstallConfirmation.phrase(for: plan.volumes)
    }

    /// Whether Uninstall may run: a plan made, and the volumes' names typed
    /// when they're to go.
    var canRun: Bool {
        guard let plan, !isBusy, done.isEmpty else { return false }
        return plan.volumes.isEmpty || UninstallConfirmation.matches(typed, roles: plan.volumes)
    }

    /// The dry run made again (the volumes' toggle changed, say).
    func look() async {
        isBusy = true
        defer { isBusy = false }
        let volumes = deleteVolumes
        do {
            plan = try await Task.detached { try UninstallRunner.plan(deleteVolumes: volumes) }.value
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }

    /// The plan run, each step said as it's done.
    func run() async {
        guard let plan, canRun else { return }
        isBusy = true
        defer { isBusy = false }
        let typed = typed
        let lines = await Task.detached { () -> [String] in
            var said: [String] = []
            UninstallRunner.run(plan, typed: plan.volumes.isEmpty ? nil : typed, route: .administratorPrompt) { said.append($0) }
            return said
        }.value
        done = lines
    }

    /// Visor Disk Utility ends, its own defaults and Saved State gone first
    /// (the window writes them again until it does).
    func finish() {
        UninstallRunner.forgetOwn()
        exit(0)
    }
}

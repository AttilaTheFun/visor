// The window's state: the survey, the sizes typed, and what's running.

import DiskVolumes
import Foundation
import Observation

/// What the window shows and does. diskutil runs off the main actor
/// (DiskTool); each look at the disks writes volumes.json for Visor.
@MainActor @Observable
final class VolumesModel {
    private(set) var states: [VolumeRole: VolumeState] = [:]
    /// The reserve and quota typed for each role, in gigabytes.
    var reserve: [VolumeRole: String] = [:]
    var quota: [VolumeRole: String] = [:]
    private(set) var isBusy = false
    /// The last failure, for an alert.
    var failure: String?
    /// Where volumes.json was last written, or why it wasn't.
    private(set) var statusLine = ""

    init() {
        for role in VolumeRole.allCases {
            reserve[role] = Self.gigabytes(role.defaultReserve)
            quota[role] = Self.gigabytes(role.defaultQuota)
        }
    }

    func refresh() async {
        await perform { try DiskTool.survey() }
    }

    func create(_ role: VolumeRole) async {
        guard let state = states[role], let sizes = sizes(for: role) else { return }
        await perform {
            try DiskTool.change(state.createCommands(reserve: sizes.reserve, quota: sizes.quota), route: .administratorPrompt)
        }
    }

    /// The container's folder on Visor emptied (Erase Containers…).
    func eraseContainers() async {
        await perform {
            _ = try DiskTool.clearContainers()
            return try DiskTool.survey()
        }
    }

    /// The typed sizes in bytes; nil, with a failure said, if one isn't a size.
    private func sizes(for role: VolumeRole) -> (reserve: Int64, quota: Int64)? {
        guard let reserve = ByteSize.gigabytes(reserve[role] ?? ""), let quota = ByteSize.gigabytes(quota[role] ?? "") else {
            failure = "\(role.volumeName)'s reserve and quota are sizes in gigabytes (empty for none)."
            return nil
        }
        return (reserve, quota)
    }

    /// Runs a look or a change off the main actor, then shows the disks as
    /// they are and writes volumes.json.
    private func perform(_ work: @escaping @Sendable () throws -> DiskSurvey) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let survey = try await Task.detached(operation: work).value
            apply(survey)
        } catch DiskVolumesError.cancelled {
            // The person said no at the prompt: nothing to report.
        } catch {
            failure = "\(error)"
            if let survey = try? await Task.detached(operation: { try DiskTool.survey() }).value { apply(survey) }
        }
    }

    private func apply(_ survey: DiskSurvey) {
        for role in VolumeRole.allCases {
            let state = survey.state(for: role)
            states[role] = state
            // An existing volume's own sizes, as they are.
            if let volume = state.volume {
                reserve[role] = Self.gigabytes(volume.reserve)
                quota[role] = Self.gigabytes(volume.quota)
            }
        }
        do {
            statusLine = "Visor reads these from \(try DiskTool.writeStatus(survey).path)."
        } catch {
            statusLine = "volumes.json couldn't be written: \(error.localizedDescription)"
        }
    }

    /// Bytes as the gigabytes a field shows ("" for none).
    private static func gigabytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let tenths = (bytes * 10 + ByteSize.gigabyte / 2) / ByteSize.gigabyte
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }
}

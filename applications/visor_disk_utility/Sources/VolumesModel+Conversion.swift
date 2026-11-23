// The window's conversion of a case-insensitive Sessions or Sources
// (docs/volume-conversion.md): Stage and Swap In, each one administrator
// prompt for every volume it applies to, and a kept volume's Delete….

import DiskVolumes
import Foundation

extension VolumesModel {
    /// The roles Stage would stage now.
    var stageable: [VolumeRole] { VolumeRole.convertible.filter { conversions[$0]?.canStage == true } }

    /// The roles Swap In would swap now: staged, copied and verified.
    var swappable: [VolumeRole] { VolumeRole.convertible.filter { conversions[$0]?.canSwap == true } }

    /// The volumes earlier conversions kept, Sessions' then Sources'.
    var kept: [KeptVolume] { VolumeRole.convertible.flatMap { conversions[$0]?.kept ?? [] } }

    /// Stage: `<Name>-new` for each role that can be staged.
    func stage() async {
        let roles = stageable
        guard !roles.isEmpty else { return }
        conversionResult = []
        if await perform({ try DiskTool.stage(roles, route: .administratorPrompt) }) {
            conversionResult = roles.map { "\($0.stagedName) staged at \($0.stagedMountPoint): now NCH runs copy-staged \($0.rawValue) over SSH." }
        }
    }

    /// Swap In: each verified copy swapped in, then what it left shown.
    func swapIn() async {
        let roles = swappable
        guard !roles.isEmpty else { return }
        conversionResult = []
        if await perform({ try DiskTool.swap(roles, route: .administratorPrompt) }), let survey {
            conversionResult = DiskTool.swapResult(roles, in: survey)
        }
    }

    /// A kept volume deleted, its confirmation typed.
    func deleteKept(_ kept: KeptVolume, typed: String) async {
        let name = kept.name
        conversionResult = []
        if await perform({ try DiskTool.deleteKept(name, typed: typed, route: .administratorPrompt) }) {
            conversionResult = ["\(name) deleted."]
        }
    }
}

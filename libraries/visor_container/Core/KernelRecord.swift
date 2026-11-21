// kernel/vmlinux.json: what the kernel beside it was taken from, and its
// own SHA-256, so a kept kernel is used only while it's the one pinned and
// its bytes are what was written.

import Foundation

struct KernelRecord: Codable, Equatable, Sendable {
    /// The archive's URL and SHA-256, and the member taken out of it.
    var url: URL
    var archiveSHA256: String
    var member: String
    /// vmlinux's own SHA-256.
    var sha256: String

    /// Whether it records the kernel `pins` names.
    func matches(_ pins: ContainerPins.Kernel) -> Bool {
        archiveSHA256 == pins.sha256 && member == pins.member
    }
}

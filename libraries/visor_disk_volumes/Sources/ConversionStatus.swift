// Where a role's conversion stands: what the window and `status` show.

public struct ConversionStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The role's volume is case-sensitive: nothing to convert.
        case converted
        /// It can't be converted now, and why (no volume, no room, a kept
        /// volume in the way).
        case unavailable(String)
        /// Stage can run.
        case ready
        /// `<Name>-new` is there, and how its copy stands.
        case staged(Verification)
    }

    public enum Verification: Equatable, Sendable {
        /// No marker: copy-staged hasn't run (or failed).
        case notCopied
        /// A marker that names these volumes, fresh: Swap In can run.
        case verified(ConversionMarker)
        /// A marker, or a copy, Swap In refuses, and why.
        case refused(String)
    }

    public var role: VolumeRole
    public var phase: Phase
    /// The staged copy, if there's one.
    public var staged: APFSVolume?
    /// The volumes earlier conversions left (`-old-ci`, `-cs-failed`).
    public var kept: [KeptVolume]

    public init(role: VolumeRole, phase: Phase, staged: APFSVolume? = nil, kept: [KeptVolume] = []) {
        self.role = role
        self.phase = phase
        self.staged = staged
        self.kept = kept
    }

    public var canStage: Bool { phase == .ready }

    public var canSwap: Bool {
        if case .staged(.verified) = phase { return true }
        return false
    }

    /// It, in a line.
    public var summary: String {
        switch phase {
        case .converted:
            "\(role.volumeName) is case-sensitive: nothing to convert."
        case let .unavailable(why):
            why
        case .ready:
            "\(role.volumeName) is case-insensitive: Stage makes \(role.stagedName), case-sensitive, beside it."
        case .staged(.notCopied):
            "\(role.stagedName) is staged\(staged.map { " (\($0.device))" } ?? ""): waiting for copy-staged \(role.rawValue) (NCH, over SSH)."
        case let .staged(.verified(marker)):
            "\(role.stagedName) is \(marker.summary). Ready to swap in."
        case let .staged(.refused(why)):
            "\(role.stagedName) is staged, but can't be swapped in: \(why)"
        }
    }
}

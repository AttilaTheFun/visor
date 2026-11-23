// Which conversion step VolumeGuard is told a run is.

import Foundation

/// The step of a role's conversion a run of commands is (VolumeGuard's
/// `converting`): its commands pass only when they're exactly what
/// ConversionPlanner plans for it from the disks as they are now.
public enum ConversionStep: Equatable, Sendable {
    /// `<Name>-new` made, case-sensitive, with the role's quota and
    /// reserve, and given to the person.
    case stage
    /// The verified copy swapped in: its marker, checked again, and the
    /// time it's checked at.
    case swap(ConversionMarker, now: Date)
    /// The old volume put back.
    case unswap
}

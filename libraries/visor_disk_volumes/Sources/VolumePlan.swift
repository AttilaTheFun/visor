// What Visor Disk Utility does about a volume.

/// Adopt the volume that's there, make one, or neither.
public enum VolumePlan: Equatable, Sendable {
    /// It's there: used as it is, never reformatted.
    case adopt
    /// It isn't: made in this APFS container (the boot disk's).
    case create(container: String)
    /// Something's in the way, said for a person; nothing is done.
    case blocked(String)
}

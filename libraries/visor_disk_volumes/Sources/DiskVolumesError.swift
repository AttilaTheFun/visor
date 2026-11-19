// What goes wrong with the volumes, said for a person.

/// Why a volume can't be read, made or erased.
public enum DiskVolumesError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A tool's output that isn't what it should be.
    case unreadable(String, String)
    /// An erase or delete aimed at Sessions, which is never erased.
    case sessionsNeverErased(String)
    /// A command Visor Disk Utility never runs.
    case notAllowed(String)
    /// A command aimed at a volume that isn't what it should be.
    case wrongTarget(String)
    /// What the plan says can't be done.
    case blocked(String)
    /// diskutil (or the authorization before it) failed.
    case failed(String)
    /// The person cancelled the administrator prompt.
    case cancelled

    public var description: String {
        switch self {
        case let .unreadable(tool, detail): "\(tool)'s output couldn't be read: \(detail)"
        case let .sessionsNeverErased(what): "Sessions is never erased or deleted (\(what))."
        case let .notAllowed(what): "Visor Disk Utility never runs \(what)."
        case let .wrongTarget(what): what
        case let .blocked(why): why
        case let .failed(why): why
        case .cancelled: "Cancelled."
        }
    }
}

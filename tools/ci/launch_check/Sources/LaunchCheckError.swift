/// Why the check couldn't be made at all (exit 2), as against the app
/// failing it (exit 1): the arguments, or the Mac it runs on.
enum LaunchCheckError: Error, CustomStringConvertible {
    /// The arguments aren't the tool's.
    case usage(String)
    /// The app couldn't be readied or opened, or the Mac isn't one the
    /// check can run on (a Visor already running, 7433 already answering).
    case setup(String)

    var description: String {
        switch self {
        case .usage(let message), .setup(let message): message
        }
    }
}

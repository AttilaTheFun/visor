import CVisorPOSIX

/// A socket file, asked whether a server listens at it.
public enum POSIXUnixSocket {
    /// Whether something takes a connection at `path` now.
    public static func answers(_ path: String) -> Bool { visor_unix_answers(path) == 1 }
}

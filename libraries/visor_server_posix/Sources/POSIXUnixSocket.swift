import CVisorPOSIX
import VisorSystem

/// A socket file: asked whether a server listens at it, or connected to.
public enum POSIXUnixSocket {
    /// Whether something takes a connection at `path` now.
    public static func answers(_ path: String) -> Bool { visor_unix_answers(path) == 1 }

    /// A connection to the socket at `path`; nil when nothing listens
    /// there.
    @MainActor public static func connect(_ path: String) async -> (any ByteStream)? {
        let descriptor = await blocking { visor_connect_unix(path) }
        guard descriptor >= 0 else { return nil }
        return POSIXSocketStream(POSIXSocket(descriptor))
    }
}

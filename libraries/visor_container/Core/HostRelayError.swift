// Why HostRelay couldn't listen.

import Foundation

public struct HostRelayError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    public var path: String
    public var errno: Int32

    public init(path: String, errno: Int32) {
        self.path = path
        self.errno = errno
    }

    public var description: String {
        "The container's relay socket \(path) can't be listened on: \(String(cString: strerror(errno)))"
            + (path.utf8.count >= 104 ? " (a socket's path must be under 104 bytes)" : "")
    }

    public var errorDescription: String? { description }
}

// The tests' stand-in executables (a server, an app, launchctl), written
// through a descriptor closed on exec, so no other test's process can hold
// one open for writing.
//
// Swift Testing runs the suites side by side in one process, and they spawn
// shells that live on (watchers, the stand-ins they start). A child inherits
// every descriptor not closed on exec, and Foundation's
// `write(toFile:atomically:)` writes through one that isn't: a spawn on
// another thread mid-write handed the stand-in, open for writing, to that
// child and to everything it started, and an exec of the stand-in seconds
// later failed with ETXTBSY ("Text file busy"). The watch ran, but the build
// it started never did (the flaky `scene.running` after a rollback, since
// AppRelaunchCommandsTests joined the suites).

import Foundation
#if canImport(Glibc)
import Glibc
#endif

enum StandIn {
    /// `script` at `path`, mode 0755, replacing what was there.
    static func executable(_ script: String, at path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o755)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let bytes = Array(script.utf8)
        var written = 0
        while written < bytes.count {
            let wrote = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress! + written, $0.count - written) }
            if wrote < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            written += wrote
        }
        // 0755 whatever the umask, which open's mode goes through.
        guard fchmod(descriptor, 0o755) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

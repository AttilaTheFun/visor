// One Visor.app at a time (AppAgentJob.launch): a lock file the running
// app holds for its life with flock(2), which the system lets go when the
// process ends, however it ends (a crash too), so a stale file never keeps
// the next one out. Its process id is written in it, for a second instance
// to bring the first forward. Opened close-on-exec: the agents' hosts and
// the update's watcher, the app's children, never hold it.
//
// Where: this user's temporary folder (`confstr(_CS_DARWIN_USER_TEMP_DIR)`
// on a Mac, the same for every process of the user's, launchd's or a
// person's), so it leaves nothing behind.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class InstanceLock: Sendable {
    /// The open file whose lock is held, until the process ends.
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The lock taken, this process's id written in it; nil when another
    /// process holds it. A file that can't be opened holds nothing: the
    /// caller runs, unguarded, rather than not at all.
    public static func take(_ path: String) -> InstanceLock? {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return InstanceLock(descriptor: -1) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let text = "\(getpid())\n"
        _ = ftruncate(descriptor, 0)
        _ = text.withCString { pwrite(descriptor, $0, strlen($0), 0) }
        return InstanceLock(descriptor: descriptor)
    }

    /// Whether another process holds it now. Asked without keeping it.
    public static func isHeld(_ path: String) -> Bool {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        _ = flock(descriptor, LOCK_UN)
        return false
    }

    /// The process id its holder wrote; nil when none is written.
    public static func holder(_ path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Let go (a test's; the app holds it until it ends).
    public func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// The lock's file for the app `bundleID`: in this user's temporary
    /// folder.
    public static func path(bundleID: String, temporary: String = userTemporaryFolder) -> String {
        (temporary as NSString).appendingPathComponent(bundleID + ".instance.lock")
    }

    /// This user's temporary folder: the system's own for the user on a
    /// Mac, whoever started the process; else the process's.
    public static var userTemporaryFolder: String {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        #endif
        return NSTemporaryDirectory()
    }
}

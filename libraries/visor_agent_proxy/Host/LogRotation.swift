// agent-proxy's own log, kept in bounds (the launchd job's: launchd opens
// `Visor-agent-proxy.log` (in Visor's logs: VisorFolders) and gives it to the process as
// its standard output and error, and never rotates it). Past `limit` (about
// 8 MB), the file is moved aside to `<path>.1` (the one before it replaced)
// and a new one opened at the path, onto the same descriptors, so what's
// written next starts it. Only while the descriptor is that file still: one
// that isn't (a terminal, another file, the path moved by someone else) is
// left alone.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum LogRotation {
    /// About 8 MB.
    public static let defaultLimit = 8 << 20
    /// How often the log's size is looked at, in seconds.
    static let interval = 60

    /// Looked at now and every `interval` seconds, standard output and
    /// error moved to a new file when `path` passes `limit`: for as long as
    /// the timer returned is held.
    static func watch(_ path: String, limit: Int, log: @escaping @Sendable (String) -> Void) -> any DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "agent-proxy.log-rotation"))
        timer.schedule(deadline: .now(), repeating: .seconds(interval))
        timer.setEventHandler {
            if rotate(path, limit: limit, descriptors: [STDERR_FILENO, STDOUT_FILENO]) {
                log("its log passed \(limit >> 20) MB: the one before is \(path).1")
            }
        }
        timer.resume()
        return timer
    }

    /// When the first of `descriptors` is the file at `path` and it has
    /// passed `limit` bytes: `path` moved to `path.1`, a new file (mode 600)
    /// opened at `path` and put in place of each of `descriptors` that was
    /// that file. True when it was moved.
    public static func rotate(_ path: String, limit: Int, descriptors: [Int32]) -> Bool {
        guard let first = descriptors.first else { return false }
        var written = stat(), named = stat()
        guard fstat(first, &written) == 0, stat(path, &named) == 0, written.st_dev == named.st_dev, written.st_ino == named.st_ino,
              Int(written.st_size) > limit else { return false }
        let same = descriptors.filter { descriptor in
            var each = stat()
            return fstat(descriptor, &each) == 0 && each.st_dev == named.st_dev && each.st_ino == named.st_ino
        }
        guard rename(path, path + ".1") == 0 else { return false }
        let fresh = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fresh >= 0 else { return true }
        for descriptor in same { _ = dup2(fresh, descriptor) }
        close(fresh)
        return true
    }
}

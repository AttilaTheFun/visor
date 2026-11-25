// Whether the process holding an update watch's lock (RelaunchWatchLock:
// `<pid> <started>`) is still that watcher, for the hand-back
// (ServerHandBack), which waits for a watch to end before it stops the
// server agent. A process id is reused: a lock left behind whose pid now
// names another process would hold the hand-back up for a whole watch's
// length (NCH's check of #537). So the process must also have started when
// the lock says its watcher did: its start time, from the system
// (`sysctl KERN_PROC_PID` on a Mac, `/proc/<pid>/stat` on Linux), within
// `tolerance` seconds of the time recorded. The watcher records it as it
// starts (and the app that starts it, at once), so its own start is
// seconds from it; a process that reused its pid started after it ended,
// minutes on.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import VisorServer

public enum RelaunchWatchHolder {
    /// How far a watcher's start may be from the time its lock records.
    public static let tolerance = 30

    /// Seconds the watch holding the lock (`text`) has left, while the
    /// process holding it is its watcher; nil when none is.
    public static func remaining(_ text: String?, now: Int, started: (Int32) -> Int? = startTime) -> Int? {
        guard let text, let held = RelaunchWatchLock.read(text) else { return nil }
        return RelaunchWatchLock.remaining(text, now: now, isRunning: { isWatcher($0, recorded: held.started, started: started) })
    }

    /// Whether process `pid` runs and started when `recorded` says.
    public static func isWatcher(_ pid: Int32, recorded: Int, started: (Int32) -> Int? = startTime) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM, let start = started(pid) else { return false }
        return abs(start - recorded) <= tolerance
    }

    /// When process `pid` started (seconds since 1970); nil when it isn't
    /// running or the system doesn't say.
    public static func startTime(_ pid: Int32) -> Int? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let count = UInt32(mib.count)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, count, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return Int(info.kp_proc.p_un.__p_starttime.tv_sec)
        #else
        // Field 22 of /proc/<pid>/stat: clock ticks after the boot, which
        // /proc/stat's `btime` gives (seconds since 1970). The command's
        // name, in parentheses, may hold spaces: fields are counted after it.
        guard let stat = proc("/proc/\(pid)/stat"), let name = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: name)...].split(separator: " ")
        guard fields.count > 19, let ticks = Int(fields[19]), let boot = bootTime() else { return nil }
        let perSecond = sysconf(Int32(_SC_CLK_TCK))
        guard perSecond > 0 else { return nil }
        return boot + ticks / perSecond
        #endif
    }

    #if !canImport(Darwin)
    /// When the system booted (seconds since 1970): /proc/stat's `btime`.
    private static func bootTime() -> Int? {
        guard let stat = proc("/proc/stat") else { return nil }
        for line in stat.split(separator: "\n") where line.hasPrefix("btime ") {
            return Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// A file of /proc's, read to its end (its size says nothing).
    private static func proc(_ path: String) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        return String(decoding: file.readDataToEndOfFile(), as: UTF8.self)
    }
    #endif
}

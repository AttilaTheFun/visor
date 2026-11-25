// Whether the process holding an update watch's lock (RelaunchWatchLock:
// `<pid> <started>`) is still that watcher, for the hand-back
// (ServerHandBack), which waits for a watch to end before it stops the
// server agent. A process id is reused: a lock left behind whose pid now
// names another process would hold the hand-back up for a whole watch's
// length (NCH's check of #537). So the process must also have started when
// the lock says its watcher did: its start time, from the system
// (POSIXProcessSignals.startTime: `sysctl KERN_PROC_PID` on a Mac,
// `/proc/<pid>/stat` on Linux), within RelaunchWatchLock.tolerance of the
// time recorded. The server's own refusal of a restart during a watch
// (VisorServer.relaunchWatched) asks the same.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import VisorServer
import VisorServerPOSIX

public enum RelaunchWatchHolder {
    /// How far a watcher's start may be from the time its lock records.
    public static let tolerance = RelaunchWatchLock.tolerance

    /// Seconds the watch holding the lock (`text`) has left, while the
    /// process holding it is its watcher; nil when none is.
    public static func remaining(_ text: String?, now: Int, started: (Int32) -> Int? = startTime) -> Int? {
        RelaunchWatchLock.remaining(text, now: now, isRunning: running, started: started)
    }

    /// Whether process `pid` runs and started when `recorded` says.
    public static func isWatcher(_ pid: Int32, recorded: Int, started: (Int32) -> Int? = startTime) -> Bool {
        RelaunchWatchLock.isWatcher(pid, recorded: recorded, isRunning: running, started: started)
    }

    /// When process `pid` started (seconds since 1970); nil when it isn't
    /// running or the system doesn't say.
    public static func startTime(_ pid: Int32) -> Int? {
        POSIXProcessSignals().startTime(of: pid)
    }

    /// Whether process `pid` runs (one another user's is, though it can't
    /// be signalled).
    private static func running(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

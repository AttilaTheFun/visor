import CVisorPOSIX
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import VisorServer
import VisorSystem

/// Signals by process id, as POSIX systems send them.
public struct POSIXProcessSignals: ProcessSignals {
    public init() {}

    public func terminate(_ pid: Int32) { signalProcess(pid, SIGTERM) }

    public func kill(_ pid: Int32) { signalProcess(pid, SIGKILL) }

    /// A process that has exited but not been reaped (its parent gone and
    /// the system's first process not reaping: a container's) still has
    /// its id, and is not running: /proc says so where there is one.
    public func isRunning(_ pid: Int32) -> Bool {
        guard processExists(pid) else { return false }
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return true }
        return stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).first != "Z"
    }

    /// From the system: `sysctl KERN_PROC_PID` on a Mac, `/proc/<pid>/stat`
    /// on Linux (moved from the launch agents' RelaunchWatchHolder, 0.72.1).
    public func startTime(of pid: Int32) -> Int? {
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
        guard let stat = Self.proc("/proc/\(pid)/stat"), let name = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: name)...].split(separator: " ")
        guard fields.count > 19, let ticks = Int(fields[19]), let boot = Self.bootTime() else { return nil }
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

    /// From /proc where the system has it (Linux); from `ps` elsewhere.
    public func commandLine(of pid: Int32) async -> String? {
        if let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty {
            return String(decoding: data.map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        return await blocking { output(of: "/bin/ps", ["-p", String(pid), "-o", "command="]).flatMap { $0.isEmpty ? nil : $0 } }
    }

    public func ignoreBrokenPipes() { visor_ignore_broken_pipes() }
}

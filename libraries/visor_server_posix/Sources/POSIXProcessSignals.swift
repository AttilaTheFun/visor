import CVisorPOSIX
import Foundation
import VisorServer

/// Signals by process id, as POSIX systems send them.
public struct POSIXProcessSignals: ProcessSignals {
    public init() {}

    public func terminate(_ pid: Int32) { signalProcess(pid, SIGTERM) }

    public func kill(_ pid: Int32) { signalProcess(pid, SIGKILL) }

    public func isRunning(_ pid: Int32) -> Bool { processExists(pid) }

    /// From /proc where the system has it (Linux); from `ps` elsewhere.
    public func commandLine(of pid: Int32) async -> String? {
        if let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty {
            return String(decoding: data.map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        return await blocking { output(of: "/bin/ps", ["-p", String(pid), "-o", "command="]).flatMap { $0.isEmpty ? nil : $0 } }
    }

    public func ignoreBrokenPipes() { visor_ignore_broken_pipes() }
}

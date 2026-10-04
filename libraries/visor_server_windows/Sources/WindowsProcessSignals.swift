import Foundation
import VisorServer
import WinSDK

/// Processes by id, as Windows has them. There are no signals: ending one
/// is TerminateProcess, so a server stops its agents itself first (its own
/// pipes, its own consoles) and keeps this for what will not go.
public struct WindowsProcessSignals: ProcessSignals {
    public init() {}

    public func terminate(_ pid: Int32) { end(pid) }

    public func kill(_ pid: Int32) { end(pid) }

    private func end(_ pid: Int32) {
        // PROCESS_TERMINATE
        guard let process = OpenProcess(DWORD(0x0001), false, DWORD(bitPattern: pid)) else { return }
        _ = TerminateProcess(process, 1)
        CloseHandle(process)
    }

    public func isRunning(_ pid: Int32) -> Bool {
        // PROCESS_QUERY_LIMITED_INFORMATION
        guard let process = OpenProcess(DWORD(0x1000), false, DWORD(bitPattern: pid)) else { return false }
        defer { CloseHandle(process) }
        var code: DWORD = 0
        // STILL_ACTIVE
        return GetExitCodeProcess(process, &code).boolValue && code == 259
    }

    /// The program's path: Windows keeps a process's command line out of
    /// reach of others, so this is what tells an agent from anything else.
    public func commandLine(of pid: Int32) async -> String? {
        guard let process = OpenProcess(DWORD(0x1000), false, DWORD(bitPattern: pid)) else { return nil }
        defer { CloseHandle(process) }
        var buffer = [WCHAR](repeating: 0, count: 32768)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(process, 0, &buffer, &size).boolValue else { return nil }
        return String(decoding: buffer[0..<Int(size)], as: UTF16.self)
    }

    /// Windows has no SIGPIPE: a write to a closed pipe already fails.
    public func ignoreBrokenPipes() {}
}

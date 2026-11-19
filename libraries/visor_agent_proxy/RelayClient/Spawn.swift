// Starting programs without Foundation's Process: it waits on a run loop
// whose wakeup is a socket pair over loopback, and in a new network
// namespace loopback is down until `ip link set lo up` has run, so that
// very command never ends. Here a child is forked and waited for directly
// (the C shim's spawns).

import CRelayClientPOSIX
import Foundation

/// A program run as a child.
public enum Spawn {
    /// Where `name` is: itself if it has a slash, else the first match on
    /// `PATH` that can be run.
    public static func locate(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        if name.contains("/") { return name }
        for folder in (path ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin").split(separator: ":") {
            let candidate = "\(folder)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    /// Runs `arguments` to its end with `input` on its standard input: its
    /// exit status (127 if it couldn't start, 128 + the signal if one ended
    /// it) and what it wrote to standard error.
    public static func run(_ arguments: [String], input: String? = nil) -> (status: Int32, errors: String) {
        guard let path = locate(arguments[0]) else { return (127, "\(arguments[0]): not found") }
        var pipes: [Int32] = [-1, -1, -1]
        let pid = withCStrings(arguments) { argv in
            withCStrings(environment()) { envp in relay_client_spawn_piped(path, argv, envp, nil, &pipes) }
        }
        guard pid > 0 else { return (127, "\(arguments[0]): couldn't be started (errno \(errno))") }
        if let input { write(all: Array(input.utf8), to: pipes[0]) }
        close(pipes[0])
        // Its output read and dropped on a thread of its own, so a child
        // that writes much to both never stops on a full pipe.
        let output = pipes[1]
        let drained = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = readAll(output)
            drained.signal()
        }
        let errors = readAll(pipes[2])
        drained.wait()
        close(pipes[1])
        close(pipes[2])
        return (wait(pid), String(decoding: errors, as: UTF8.self))
    }

    /// Starts `arguments` keeping this process's standard streams: its
    /// process id, or nil (nothing by that name, or no fork).
    public static func start(_ arguments: [String]) -> pid_t? {
        guard let path = locate(arguments[0]) else { return nil }
        let pid = withCStrings(arguments) { argv in withCStrings(environment()) { envp in relay_client_spawn_inheriting(path, argv, envp) } }
        return pid > 0 ? pid : nil
    }

    /// Waits for `pid` to end: its exit status, or 128 + the signal that
    /// ended it.
    public static func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        var signaled: Int32 = 0
        guard relay_client_wait(pid, &status, &signaled) == 0 else { return 127 }
        return signaled != 0 ? 128 + status : status
    }

    private static func environment() -> [String] {
        ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
    }

    private static func withCStrings<Result>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result {
        let copies: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
        defer { for copy in copies { free(copy) } }
        return copies.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private static func write(all bytes: [UInt8], to descriptor: Int32) {
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress! + sent, bytes.count - sent) }
            if wrote <= 0 { return }
            sent += wrote
        }
    }

    private static func readAll(_ descriptor: Int32) -> [UInt8] {
        var all: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { return all }
            all += buffer[0..<count]
        }
    }
}

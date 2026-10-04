import CVisorPOSIX
import Foundation

/// Starting a program as a daemon: the leader of a new session with no
/// terminal, so it outlives the terminal it was started from.
public enum POSIXDaemon {
    /// Starts `executable` with `arguments` and this process's environment,
    /// its output and errors appended to the file at `log`. Its process id.
    public static func start(_ executable: String, _ arguments: [String], log: String) throws -> Int32 {
        let descriptor = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: "Visor", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(log): \(String(cString: strerror(errno)))"])
        }
        defer { closeDescriptor(descriptor) }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        let pid = visor_spawn_detached(executable, argv, envp, descriptor)
        guard pid > 0 else {
            throw NSError(domain: "Visor", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        return pid
    }
}

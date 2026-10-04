import Foundation

/// The user the server runs as, as the system's account database has them.
public enum POSIXUser {
    /// Their login shell (their account's, then `SHELL`, then `fallback`).
    public static func loginShell(fallback: String) -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return fallback
    }

    /// Where `shell`, started as a login shell, finds `tool` on the user's
    /// PATH; nil when it does not.
    public static func locate(_ tool: String, with shell: String) async -> String? {
        await blocking {
            guard let path = output(of: shell, ["-lc", "command -v \(tool)"]), path.hasPrefix("/") else { return nil }
            return path
        }
    }
}

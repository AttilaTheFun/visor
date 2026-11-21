import Foundation

/// `~` and `~/…` against `home` (the settings' `agentToken` and
/// `auditLog`); any other path as it is.
public func expandingTilde(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    return path
}

/// The user's home: $HOME, else the password database's.
public func homeDirectory() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
    return FileManager.default.homeDirectoryForCurrentUser.path
}

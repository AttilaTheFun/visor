import Foundation

/// What an administrator's managed settings for Claude Code allow of its
/// permission modes, read where Claude Code reads them (the system's
/// `ToolLocating.claudeManagedSettings`: managed preferences, a
/// managed-settings.json). A mode any of them disables is disabled.
struct ClaudeManagedPolicy: Equatable {
    /// `permissions.disableBypassPermissionsMode` is "disable".
    var bypassDisabled = false
    /// `permissions.disableAutoMode` is "disable".
    var autoDisabled = false

    /// The policy on this computer.
    static var current: ClaudeManagedPolicy { read(ServerPlatform.current.tools.claudeManagedSettings) }

    /// The policy the files at `paths` set, together; none where there
    /// are none (an unmanaged computer).
    static func read(_ paths: [String]) -> ClaudeManagedPolicy {
        var policy = ClaudeManagedPolicy()
        for path in paths {
            guard let permissions = settings(at: path)?["permissions"] as? [String: Any] else { continue }
            if permissions["disableBypassPermissionsMode"] as? String == "disable" { policy.bypassDisabled = true }
            if permissions["disableAutoMode"] as? String == "disable" { policy.autoDisabled = true }
        }
        return policy
    }

    /// The settings in a file: a property list (managed preferences) or
    /// JSON.
    private static func settings(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if path.hasSuffix(".plist") {
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The mode an auto-approving session starts Claude in: bypassing
    /// permissions, or Claude's own auto mode where the policy disables
    /// bypassing and not auto. Where it disables both, bypassing is still
    /// asked for: Claude starts in another mode, says so, and the session
    /// becomes manual.
    var autoApproveMode: String { bypassDisabled && !autoDisabled ? "auto" : "bypassPermissions" }
}

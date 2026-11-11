// Permission prompts by where an agent runs (Logan, 11 Nov: "i want native
// sessions to use the builtin auto approve / manual approval and only
// container sessions would dangerously skip since they can only touch the
// mounted volumes"). In a container — this server's own (VISOR_IN_CONTAINER,
// or one found: HostDetails.inContainer), its agents with it — a session's
// agent always skips them (Claude Code's bypassPermissions, Codex's
// danger-full-access with no approvals): a client can't make it ask. On the
// computer itself the session chooses: auto-approving, which is Claude
// Code's own auto mode and Codex in its sandbox, never a bypass
// (ClaudeManagedPolicy.autoApproveMode, CodexAppServerProcess), or manual.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Whether the agent of `info` runs in a container: this server's own,
    /// as every agent here does (sessions in containers of their own were
    /// removed in 0.50).
    func runsContained(_ info: SessionInfo) -> Bool {
        ServerPlatform.current.host.inContainer
    }

    /// `info` with its permissions as they are here: a contained session's
    /// always auto-approving; another's as it chose.
    func withPermissions(_ info: SessionInfo) -> SessionInfo {
        guard runsContained(info) else { return info }
        var info = info
        info.skipPermissions = true
        return info
    }
}

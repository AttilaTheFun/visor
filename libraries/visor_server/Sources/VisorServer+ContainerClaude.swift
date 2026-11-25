// Containers only means no Claude Code of this Mac's own (docs/containers.md,
// Containers only): while the Sessions container is on, the `claude -p` the
// server runs for itself runs there instead (SessionsContainer.run), with
// the container's Claude folder on Sessions (`CLAUDE_CONFIG_DIR=
// <Sessions>/.claude`), as its sessions' agents have it. Otherwise Claude
// Code here would write ~/.claude, ~/.claude.json and the keychain's
// "Claude Code-credentials" on a Mac whose sessions are all in the
// container.
//
// - The models' `initialize`, every few hours (keepModelsFresh): asked of
//   the container only while it's running (never started for it); while
//   it isn't, the list held stands.
// - Super Compact's calls (SuperCompaction): each in the container,
//   started for it if it isn't running.

import Foundation
import VisorAgent
import VisorProtocol

extension VisorServer {
    /// Whether the server's own `claude -p` runs in the Sessions container:
    /// it's on, on a server that has one.
    var claudeRunsInContainer: Bool { sessionsContainer != nil && settings.container?.enabled == true }

    /// The environment of `claude` in the container: its Claude folder on
    /// Sessions, and the credential's placeholder and agent-proxy's
    /// authorities (VisorServer+ContainerCredential); nil when it shares no
    /// Sessions volume.
    func containerClaudeEnvironment() -> [String: String]? {
        guard let sessions = sessionsContainer?.sharedFolders.first else { return nil }
        return Self.containerClaudeEnvironment(sessions: sessions)
    }

    /// The models asked of Claude Code: in the container while it's on (and
    /// only while it's running), else here.
    func refreshClaudeModels() async -> ModelRefresh {
        guard claudeRunsInContainer else { return await ClaudeHarness.refreshModels() }
        guard let container = sessionsContainer, let environment = containerClaudeEnvironment(),
              await container.status().state == .running else { return .unchanged }
        let command = ContainerCommand(arguments: ["claude"] + ClaudeHarness.modelsArguments, environment: environment,
                                       input: Data((ClaudeHarness.modelsRequest + "\n").utf8), limit: .seconds(60),
                                       answered: { ClaudeHarness.models(inOutput: $0) != nil })
        guard let ran = try? await container.run(command) else { return .unchanged }
        return ClaudeHarness.take(ClaudeHarness.models(inOutput: ran.text))
    }

    /// How Super Compact calls `claude -p` while the container is on: in
    /// it; nil to call it here.
    func superCompactCaller() -> SuperCompaction.Caller? {
        guard claudeRunsInContainer, let container = sessionsContainer, let environment = containerClaudeEnvironment() else { return nil }
        return { arguments, input, limit, stopping in
            let command = ContainerCommand(arguments: ["claude"] + arguments, environment: environment, input: input, limit: limit,
                                           stopping: stopping)
            guard let ran = try? await container.run(command) else { return nil }
            return (ran.status, ran.text, ran.stopped)
        }
    }
}

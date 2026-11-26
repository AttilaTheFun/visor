// The git identity of the Sessions container's agents (docs/containers.md,
// "Claude's credential", git's identity in the container; 0.72.1, from
// Logan's container test on 0.71.1: `git commit` there failed, "unable to
// auto-detect email address (got root@visor-sessions.(none))"). Their
// pushes go through agent-proxy's GitHub gate as the GitHub App, so their
// commits are the App's bot's too: `<slug>[bot]` and
// `<id>+<slug>[bot]@users.noreply.github.com`, found by agent-proxy
// (GitHubAppTokens) and asked of it here through `containerGitIdentity`,
// which the agent-proxy in this process answers (MacAgentProxy). Given as
// git's environment (GIT_AUTHOR_NAME and _EMAIL, GIT_COMMITTER_NAME and
// _EMAIL) to each agent started there, beside gh's and Claude's
// placeholders. Without the App, or with no answer from GitHub, none is
// given, as before, and agent-proxy says why in the log, once. An agent's
// start waits for it ten seconds at most (found at agent-proxy's start,
// it's kept, so it's there at once); past that, it starts without one,
// said, and the finding goes on for the next. Sessions on this Mac keep
// its user's own git config.

import Foundation

/// Who the container's agents commit as.
public struct ContainerGitIdentity: Equatable, Sendable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// git's environment for it: author and committer alike.
    public var environment: [String: String] {
        ["GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email]
    }
}

extension VisorServer {
    /// How long an agent's start waits for its git identity.
    nonisolated static let containerGitIdentityWait: Duration = .seconds(10)

    /// Who a container agent starting now commits as: agent-proxy's
    /// answer, or none once `containerGitIdentityWait` has gone by (said).
    func containerGitIdentityForStart() async -> ContainerGitIdentity? {
        guard let ask = containerGitIdentity else { return nil }
        let (answers, answering) = AsyncStream.makeStream(of: ContainerGitIdentity?.self)
        // Asked on its own: one past the wait still ends, and is kept for the next.
        Task {
            answering.yield(await ask())
            answering.finish()
        }
        let wait = Self.containerGitIdentityWait
        let timer = Task {
            try await Task.sleep(for: wait)
            Self.log("container: no git identity from agent-proxy within \(wait): this agent starts without one")
            answering.yield(nil)
            answering.finish()
        }
        defer { timer.cancel() }
        for await answer in answers { return answer }
        return nil
    }
}

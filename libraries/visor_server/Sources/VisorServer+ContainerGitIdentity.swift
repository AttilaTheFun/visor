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
//
// agent-proxy is folded in after the server's start (MacServer.run), and
// the container's sessions are carried on at it: the agents started then
// had none (0.72.3, Container Test: "agent-proxy: github: commits as …"
// logged just after they started). So the server is told before it starts
// that the asking is to come (`containerGitIdentityExpected`), and a start
// before it's set waits for it, its fold-in and its answer within the same
// ten seconds.

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

/// A start waiting for `containerGitIdentity` to be set: given it once
/// it is, or none once its wait is over (`timer`).
struct ContainerGitIdentityWaiter {
    let continuation: CheckedContinuation<VisorServer.ContainerGitIdentityAsk?, Never>
    let timer: Task<Void, Never>
}

extension VisorServer {
    /// How the agent-proxy in this process is asked.
    typealias ContainerGitIdentityAsk = @Sendable () async -> ContainerGitIdentity?

    /// Who a container agent starting now commits as: agent-proxy's
    /// answer, waited for while it's expected and not yet folded in, or
    /// none once `containerGitIdentityWait` has gone by (said).
    func containerGitIdentityForStart() async -> ContainerGitIdentity? {
        guard containerGitIdentity != nil || containerGitIdentityExpected else { return nil }
        let wait = containerGitIdentityWait
        let clock = ContinuousClock()
        let began = clock.now
        let said = "container: no git identity from agent-proxy within \(wait): this agent starts without one"
        guard let ask = await containerGitIdentitySet(within: wait) else {
            Self.log(said)
            return nil
        }
        let left = wait - (clock.now - began)
        let (answers, answering) = AsyncStream.makeStream(of: ContainerGitIdentity?.self)
        // Asked on its own: one past the wait still ends, and is kept for the next.
        Task {
            answering.yield(await ask())
            answering.finish()
        }
        let timer = Task {
            try await Task.sleep(for: left)
            Self.log(said)
            answering.yield(nil)
            answering.finish()
        }
        defer { timer.cancel() }
        for await answer in answers { return answer }
        return nil
    }

    /// `containerGitIdentity`, at once when it's set; else once it is, or
    /// none if it isn't within `wait`.
    private func containerGitIdentitySet(within wait: Duration) async -> ContainerGitIdentityAsk? {
        if let containerGitIdentity { return containerGitIdentity }
        let key = UUID()
        return await withCheckedContinuation { continuation in
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.containerGitIdentityWaiters.removeValue(forKey: key)?.continuation.resume(returning: nil)
            }
            containerGitIdentityWaiters[key] = ContainerGitIdentityWaiter(continuation: continuation, timer: timer)
        }
    }

    /// `containerGitIdentity` set: the starts waiting for it go on, each
    /// asking it.
    func containerGitIdentityGiven(_ ask: @escaping ContainerGitIdentityAsk) {
        let waiting = containerGitIdentityWaiters.values
        containerGitIdentityWaiters = [:]
        for waiter in waiting {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: ask)
        }
    }
}

// Super Compact in the fixture: a job of the chat's that the screen
// chooses (running, done for review, or cut over), one started here that
// runs to its end over a few polls, HANDOFF.md kept as edited, and the
// cut-over, after which the chat is listed archived and carried on as
// VisorFixture.continuedSession.

import VisorProtocol

extension FixtureAgentServer {
    var superCompacts: Bool { true }

    /// The chat's job: the screen's at first, then as the calls leave it.
    private var job: SuperCompactStatus? {
        get {
            if !superCompactSeeded {
                superCompactSeeded = true
                superCompactJob = switch VisorFixture.screen {
                case "super-compact-running": VisorFixture.superCompact(.map)
                case "super-compact-review": VisorFixture.superCompact(.done)
                case "super-compact-done": VisorFixture.superCompact(.done, continued: true)
                default: nil
                }
            }
            return superCompactJob
        }
        set {
            superCompactSeeded = true
            superCompactJob = newValue
        }
    }

    func superCompact(of session: String) async throws -> SuperCompactStatus? {
        guard session == VisorFixture.chatSession else { return nil }
        // A job started here goes on a step at each look: ten chunks, then
        // the merge, then done.
        if superCompactFinishes, var running = job, !running.phase.ended {
            switch running.phase {
            case .prefilter: running.phase = .map
            case .map where running.chunk + 10 < running.chunks: running.chunk += 10
            case .map: running = VisorFixture.superCompact(.merge)
            default: running = VisorFixture.superCompact(.done)
            }
            job = running
        }
        return job
    }

    func startSuperCompact(_ session: String) async throws -> SuperCompactStatus {
        guard session == VisorFixture.chatSession else {
            throw AgentServerError.message("Super Compact reads Claude Code's conversations: this one is Codex's.")
        }
        superCompactFinishes = true
        let started = VisorFixture.superCompact(.map, chunk: 0)
        job = started
        superCompactHandoff = VisorFixture.handoff
        return started
    }

    func cancelSuperCompact(_ session: String) async throws -> SuperCompactStatus {
        guard var current = job else { throw AgentServerError.message("No super compact is running for “Offline sync”.") }
        if current.awaitsReview {
            current.discarded = true
        } else if !current.phase.ended {
            current.failedIn = current.phase
            current.phase = .cancelled
        } else {
            throw AgentServerError.message("No super compact is running for “Offline sync”.")
        }
        job = current
        return current
    }

    func superCompactHandoff(of session: String) async throws -> String {
        guard job?.phase == .done else { throw AgentServerError.message("The last super compact of “Offline sync” is not done.") }
        return superCompactHandoff
    }

    func saveSuperCompactHandoff(of session: String, text: String) async throws -> SuperCompactStatus {
        guard let current = job, current.awaitsReview else { throw AgentServerError.message("The handoff has been started from already.") }
        superCompactHandoff = text
        return current
    }

    func superCompactCutover(_ session: String) async throws -> (session: String, sessions: [SessionInfo]) {
        guard var current = job, current.awaitsReview else { throw AgentServerError.message("The handoff isn't waiting for its review.") }
        current.continuedAs = VisorFixture.continuedSession
        job = current
        cutOver = true
        return (VisorFixture.continuedSession, try await sessions())
    }
}

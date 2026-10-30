// Side questions on Codex (docs/sub-sessions.md): each asked on a throwaway
// copy of the thread (`thread/fork`, ephemeral), a turn of its own there
// whose answer is the question's; the session's thread is not touched.

import Foundation
import VisorProtocol

extension CodexAppServerProcess {
    /// A side question's thread, while its turn runs: what it has said so
    /// far, and who waits for the answer.
    struct Side {
        var answer: String?
        var failure: String?
        let done: CheckedContinuation<String, Error>
    }

    /// What a side question's copy of the thread is told besides the
    /// question.
    static let sideInstructions = """
        This is a side question about the conversation so far, asked while the work goes on elsewhere. \
        Answer it briefly from what you already know, without running commands, using tools or changing anything.
        """

    public func askSide(_ question: String, after earlier: [SideQuestion]) async throws -> String {
        let child = try running() ?? spawn()
        // A fork being made is the thread asked about once it has its id.
        if let forkMade { _ = await forkMade.value }
        guard let from = threadID else {
            throw AgentProcessError.declined("Nothing to ask about yet: the conversation hasn't begun.")
        }
        var params = threadParams()
        params["threadId"] = from
        params["ephemeral"] = true
        params["excludeTurns"] = true
        params["sandbox"] = "read-only"
        params["developerInstructions"] = Self.sideInstructions
        let fork = await request("thread/fork", params, of: child)
        guard let side = fork.thread else {
            throw AgentProcessError.declined("Codex could not ask on the side: \(fork.error ?? "no thread came back")")
        }
        let prompt = Self.sidePrompt(question, after: earlier)
        return try await withCheckedThrowingContinuation { done in
            sides[side] = Side(done: done)
            Task {
                let reply = await self.request("turn/start", ["threadId": side, "input": [["type": "text", "text": prompt]]], of: child)
                if let error = reply.error { self.finishSide(side, failure: error) }
            }
        }
    }

    /// The question, after the ones asked on the side before it and their
    /// answers: each copy of the thread knows only the conversation.
    static func sidePrompt(_ question: String, after earlier: [SideQuestion]) -> String {
        let asked = earlier.compactMap { side in side.answer.map { "Q: \(side.question)\nA: \($0)" } }
        guard !asked.isEmpty else { return question }
        return "Asked on the side before this:\n\n" + asked.joined(separator: "\n\n") + "\n\nNow: " + question
    }

    /// What the app server says of a side question's thread: its last
    /// message is the answer, given when its turn ends.
    func hearSide(_ output: CodexOutput, on thread: String) {
        switch output {
        case .messageCompleted(_, let text):
            sides[thread]?.answer = text
        case .failure(let message):
            sides[thread]?.failure = message
        case .turnCompleted(let failure):
            finishSide(thread, failure: failure)
        default:
            break
        }
    }

    func finishSide(_ thread: String, failure: String?) {
        guard let side = sides.removeValue(forKey: thread) else { return }
        if let answer = side.answer, !answer.isEmpty {
            side.done.resume(returning: answer)
        } else {
            side.done.resume(throwing: AgentProcessError.declined(failure ?? side.failure ?? "Codex gave no answer."))
        }
        // Its copy of the thread is let go: it was never written down.
        if let child = running() {
            Task { _ = await self.request("thread/unsubscribe", ["threadId": thread], of: child) }
        }
    }
}

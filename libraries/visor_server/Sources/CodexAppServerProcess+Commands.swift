// Codex's own slash commands (CodexCommand), as its app-server takes them:
// a goal set, paused, resumed or cleared is a request on the thread, and
// Codex then starts the goal's turns itself; a compaction and a review are
// requests too. What has no row of its own in the transcript is answered
// with a notice.

import VisorProtocol

extension CodexAppServerProcess {
    func perform(_ command: CodexCommand, on child: PipedChild) async {
        switch command {
        case .showGoal: await showGoal(on: child)
        case .setGoal(let objective): await setGoal(["objective": objective, "status": "active"], on: child)
        case .pauseGoal: await setGoal(["status": "paused"], on: child)
        case .resumeGoal: await setGoal(["status": "active"], on: child)
        case .clearGoal: await clearGoal(on: child)
        case .compact: await compact(on: child)
        case .review(let instructions): await review(instructions, on: child)
        }
    }

    private func showGoal(on child: PipedChild) async {
        guard let threadID else { tell("No goal is set. /goal followed by an objective sets one."); return }
        let reply = await request("thread/goal/get", ["threadId": threadID], of: child)
        if let error = reply.error { fail("Codex: \(error)"); return }
        tell((reply.goal ?? nil)?.summary ?? "No goal is set. /goal followed by an objective sets one.")
    }

    /// Sets the goal's objective or status, as the user (Codex takes a
    /// change from anyone else as no authority of the user's).
    private func setGoal(_ change: [String: String], on child: PipedChild) async {
        guard let threadID = await thread(on: child) else { return }
        var params: [String: Any] = ["threadId": threadID, "origin": "user"]
        for (key, value) in change { params[key] = value }
        let reply = await request("thread/goal/set", params, of: child)
        if let error = reply.error { fail("Codex: \(error)") }
    }

    private func clearGoal(on child: PipedChild) async {
        guard let threadID else { tell("No goal is set."); return }
        let reply = await request("thread/goal/clear", ["threadId": threadID, "origin": "user"], of: child)
        if let error = reply.error { fail("Codex: \(error)") }
    }

    private func compact(on child: PipedChild) async {
        guard let threadID else { tell("Nothing to compact yet."); return }
        let reply = await request("thread/compact/start", ["threadId": threadID], of: child)
        if let error = reply.error { fail("Codex: \(error)"); return }
        tell("Codex is compacting the conversation.")
    }

    private func review(_ instructions: String?, on child: PipedChild) async {
        guard let threadID = await thread(on: child) else { return }
        let target: [String: String] = instructions.map { ["type": "custom", "instructions": $0] } ?? ["type": "uncommittedChanges"]
        let reply = await request("review/start", ["threadId": threadID, "target": target, "delivery": "inline"], of: child)
        if let error = reply.error { fail("Codex: \(error)"); return }
        tell(instructions == nil ? "Codex is reviewing the uncommitted changes." : "Codex is reviewing.")
    }

    private func tell(_ words: String) { emit.yield(.notice(words)) }
    private func fail(_ problem: String) { emit.yield(.failure(problem)) }
}

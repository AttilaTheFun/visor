// Codex's subagents (docs/sub-sessions.md): threads of their own, sent off
// from the session's. The session's rollout says each one sent off and
// finished (`SubAgentActivity`); each one's own rollout holds its work,
// after the copy of the session's conversation it started from. A running
// one hears the person through the session's agent (`send_message`, by its
// path); a finished one goes on as a session of its own, its thread resumed.

import Foundation
import VisorProtocol

extension CodexHarness {
    public func subagents(id: String, cwd: String) -> [SubagentInfo] {
        guard let file = SessionCatalog.codexRollout(id: id), let data = try? Data(contentsOf: file) else { return [] }
        return Self.subagents(inRollout: data)
    }

    public func subagentTranscript(id: String, cwd: String, subagent: String) -> [TranscriptEntry] {
        guard let file = SessionCatalog.codexRollout(id: subagent), let data = try? Data(contentsOf: file) else { return [] }
        return TranscriptAssembler.rows(in: CodexRolloutParser().lines(in: Self.ownPart(of: data, thread: subagent)).compactMap(\.record))
    }

    /// Its thread, as it is: a session resumes it.
    public func continueSubagent(id: String, cwd: String, subagent: String) -> String? {
        subagents(id: id, cwd: cwd).first { $0.id == subagent && !$0.running }?.id
    }

    public func wordsForSubagent(_ words: String, to subagent: SubagentInfo) -> String {
        "For your subagent \(subagent.type) (thread \(subagent.id)), from me: pass this on to it with send_message, as it is, "
            + "and go on with what you were doing.\n\n\(words)"
    }

    /// The subagents a session's rollout says it sent off, in order: each
    /// by its thread, named by the last part of its path, running until
    /// the rollout says it finished.
    static func subagents(inRollout data: Data) -> [SubagentInfo] {
        var listed: [SubagentInfo] = []
        for object in CodexRolloutParser.objects(in: data) {
            guard let payload = object["payload"] as? [String: Any], payload["type"] as? String == "item_completed",
                  let item = payload["item"] as? [String: Any], item["type"] as? String == "SubAgentActivity",
                  let thread = item["agent_thread_id"] as? String else { continue }
            let path = item["agent_path"] as? String ?? ""
            if let index = listed.firstIndex(where: { $0.id == thread }) {
                if item["kind"] as? String == "completed" { listed[index].running = false }
            } else if item["kind"] as? String == "started" {
                listed.append(SubagentInfo(id: thread, description: CodexOutput.subagentName(path), type: path, running: true,
                                           call: item["id"] as? String))
            }
        }
        return listed
    }

    /// A subagent's rollout from where its own work begins: before that is
    /// the copy of the session's conversation it started from, whose
    /// records name the session's thread.
    static func ownPart(of data: Data, thread: String) -> Data {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let start = lines.firstIndex { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return false }
            return payload["thread_id"] as? String == thread
        }
        guard let start else { return data }
        return Data(lines[start...].joined(separator: [0x0A]))
    }
}

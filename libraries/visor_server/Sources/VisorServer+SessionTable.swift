// Every session as a table, for notes or another agent.

import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

extension VisorServer {
    /// Every session as a markdown table: the computer, each project (its
    /// name and the folder it is), and the sessions in it with the id that
    /// resumes them. What to paste into notes, or into another agent.
    public func sessionTable() -> String {
        let computer = hostName
        var rows: [String] = [
            "| Computer | Project | Folder | Session | Agent | ID |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        let ordered = sessions.sorted {
            ($0.info.cwd, $0.info.title.lowercased()) < ($1.info.cwd, $1.info.title.lowercased())
        }
        for record in ordered {
            let info = record.info
            let folder = HostFolders.resolve(info.cwd)
            let project = (folder as NSString).lastPathComponent
            let title = info.title.isEmpty ? info.agent.title : info.title
            // The agent's own id, not ours: it is the one that resumes the
            // conversation in a terminal. Empty until the first turn.
            let id = record.process.resumeID ?? info.id
            let state = info.archived ? " (archived)" : ""
            rows.append("| \(computer) | \(project) | `\(folder)` | \(title)\(state) | \(info.agent.title) | `\(id)` |")
        }
        if ordered.isEmpty { rows.append("| \(computer) | — | — | no sessions | — | — |") }
        return rows.joined(separator: "\n") + "\n"
    }
}

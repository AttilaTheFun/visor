// The dispatcher's jobs kept beside the server's sessions (jobs.json): a
// server that restarts (an install, a crash) keeps its queue, its moved
// sessions and the claims its runners hold. Without them, a runner's next
// renewal was refused and its agents ended, and a wrapper dialling back
// wasn't known for its session's: every session moved into a container
// came back (14 Nov 2026). A claim taken up from the file holds a full
// claim's length from the start, for its runner to renew.

import Foundation

extension JobQueue {
    struct Stored: Codable {
        var waiting: [StoredJob] = []
        var claimed: [Claim] = []
        var moves: [Move] = []
        var returns: [String: Int] = [:]

        struct Claim: Codable {
            var job: StoredJob
            var runner: String
        }

        struct Move: Codable {
            var agent: String
            var session: String
            var resume: String
            var cwd: String
        }
    }

    /// What is kept now.
    var stored: Stored {
        Stored(waiting: waiting.map(StoredJob.init),
               claimed: claimed.map { Stored.Claim(job: StoredJob($0.value.job), runner: $0.value.runner) },
               moves: movedSessions.compactMap { agent, session in
                   moves[agent].map { Stored.Move(agent: agent, session: session, resume: $0.resume, cwd: $0.cwd) }
               },
               returns: returns)
    }

    /// Writes what is kept, where the queue was given a file.
    func save() {
        guard let file else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(stored).write(to: file, options: .atomic)
        } catch {
            log("dispatcher: its jobs couldn't be kept in \(file.path): \(error)")
        }
    }

    /// What a file kept, if any.
    static func read(_ file: URL?) -> Stored? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }
}

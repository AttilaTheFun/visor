// The memory guard: every few seconds the agent and everything it started
// are weighed. Past the limit, the process holding the most is asked to
// stop, and made to a few seconds later — usually a command the agent ran,
// which the agent sees fail and can do otherwise; the agent itself when
// it is what holds the memory. The session is told which, and why.

import AgentHostWire
import Foundation

extension AgentHost {
    func guardMemory() {
        guard agent > 0, ended == nil else { return }
        let tree = ProcessTree(root: agent)
        let total = tree.memory
        if attached, total.distance(to: lastMemory).magnitude > max(lastMemory / 50, 16 << 20) {
            lastMemory = total
            server?.write(AgentHostFrame.memory(total).encoded)
        }
        let running = Set(tree.members.map(\.pid))
        stopping = stopping.filter { running.contains($0.key) }
        guard limit > 0, total > limit, let largest = tree.largest else { return }
        if let asked = stopping[largest.pid] {
            if Date().timeIntervalSince(asked) > 5 { kill(largest.pid, SIGKILL) }
            return
        }
        stopping[largest.pid] = Date()
        kill(largest.pid, SIGTERM)
        let which = largest.pid == agent ? "the agent itself" : "\(largest.name) (process \(largest.pid))"
        tell("Visor stopped \(which), which was using \(Self.gigabytes(largest.memory)): this session's agent and what it runs "
             + "were using \(Self.gigabytes(total)), over the session's limit of \(Self.gigabytes(limit)).")
    }

    /// "12.3 GB".
    static func gigabytes(_ bytes: UInt64) -> String {
        let tenths = (bytes * 10 + (1 << 29)) >> 30
        return "\(tenths / 10).\(tenths % 10) GB"
    }
}

import CVisorPOSIX

/// A process and everything it started, as they stand now: what the
/// memory guard weighs.
struct ProcessTree {
    struct Member: Equatable {
        var pid: Int32
        var name: String
        var memory: UInt64
    }

    /// The root first, then what it started, and what those started.
    let members: [Member]

    /// The tree under `root` now; empty when it is not running.
    init(root: Int32) {
        var table = [visor_process](repeating: visor_process(), count: 8192)
        let count = Int(visor_processes(&table, Int32(table.count)))
        self.init(root: root, table: table.prefix(max(0, count)).map { process in
            let name = withUnsafeBytes(of: process.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return (process.pid, process.parent, Member(pid: process.pid, name: name, memory: process.memory))
        })
    }

    /// The tree under `root` among these processes (each with its parent).
    init(root: Int32, table: [(pid: Int32, parent: Int32, member: Member)]) {
        var children: [Int32: [Member]] = [:]
        var rootMember: Member?
        for entry in table {
            if entry.pid == root { rootMember = entry.member }
            children[entry.parent, default: []].append(entry.member)
        }
        guard let rootMember else { members = []; return }
        var found = [rootMember]
        var index = 0
        var seen: Set<Int32> = [root]
        while index < found.count {
            for child in children[found[index].pid] ?? [] where seen.insert(child.pid).inserted { found.append(child) }
            index += 1
        }
        members = found
    }

    var memory: UInt64 { members.reduce(0) { $0 + $1.memory } }

    /// The one holding the most.
    var largest: Member? { members.max { $0.memory < $1.memory } }
}

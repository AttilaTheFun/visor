// Claude Code's store moved with its sessions: each old folder's project
// (`~/.claude/projects/<key>/`, the key the folder with every character but
// a letter or a digit made a dash) merged into the target's. Transcripts are
// kept by session id, so they don't clash. Memory is a folder per project
// with an index (MEMORY.md): several projects' merged keep every file, a
// clashing name prefixed by the folder it came from, and the indexes are
// combined under a heading for each.

import Foundation

extension FolderMove {
    var claudeProjects: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }

    /// Claude Code's key for a folder: "/Users/logan/Developer" →
    /// "-Users-logan-Developer" (each UTF-16 unit not an ASCII letter or
    /// digit a dash, as Claude Code makes it).
    public static func claudeKey(_ folder: String) -> String {
        String(folder.utf16.map { unit -> Character in
            let ascii = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            return ascii ? Character(UnicodeScalar(UInt8(unit))) : "-"
        })
    }

    func planClaude(_ plan: inout Plan) {
        let manager = FileManager.default
        let targetKey = Self.claudeKey(target)
        let moving = Set(plan.folders.map(Self.claudeKey))
        let existing = ((try? manager.contentsOfDirectory(atPath: claudeProjects.path)) ?? []).sorted()
        plan.claudeProjects = existing.filter { moving.contains($0) && $0 != targetKey }
        plan.claudeProjectsLeft = existing.filter { !moving.contains($0) && $0 != targetKey }
        plan.memoryRenames = memoryRenames(plan.claudeProjects, folders: plan.folders)
        plan.historyLines = historyChanges(Set(plan.folders)).count
        plan.claudeConfigProjects = claudeConfigProjects(Set(plan.folders))
    }

    func applyClaude(_ plan: Plan) throws -> [String] {
        var done: [String] = []
        let manager = FileManager.default
        let targetProject = claudeProjects.appendingPathComponent(Self.claudeKey(target), isDirectory: true)
        if !plan.claudeProjects.isEmpty { try manager.createDirectory(at: targetProject, withIntermediateDirectories: true) }
        try mergeMemory(plan.claudeProjects, folders: plan.folders, into: targetProject.appendingPathComponent("memory", isDirectory: true))
        for key in plan.claudeProjects {
            let source = claudeProjects.appendingPathComponent(key, isDirectory: true)
            var moved = 0
            var clashed: [String] = []
            for name in try manager.contentsOfDirectory(atPath: source.path) where name != "memory" {
                let destination = targetProject.appendingPathComponent(name)
                if manager.fileExists(atPath: destination.path) {
                    clashed.append(name)
                    continue
                }
                try manager.moveItem(at: source.appendingPathComponent(name), to: destination)
                moved += 1
            }
            if clashed.isEmpty, (try? manager.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
                try manager.removeItem(at: source)
            }
            done.append("Claude project \(key): \(moved) moved" + (clashed.isEmpty ? "" : ", left (already there): " + clashed.joined(separator: ", ")))
        }
        let history = historyChanges(Set(plan.folders))
        if !history.isEmpty {
            try rewriteHistory(Set(plan.folders))
            done.append("Prompt history: \(history.count) lines given \(target)")
        }
        if !plan.claudeConfigProjects.isEmpty {
            try rewriteClaudeConfig(Set(plan.folders))
            done.append("~/.claude.json: \(plan.claudeConfigProjects.count) projects given \(target)")
        }
        return done
    }

    // MARK: Memory

    /// For each project's memory, in order, its files whose names are taken
    /// by the target's or an earlier project's (with other contents): the
    /// old path and the new name.
    func memoryRenames(_ keys: [String], folders: [String]) -> [String: String] {
        let manager = FileManager.default
        let target = claudeProjects.appendingPathComponent(Self.claudeKey(self.target), isDirectory: true).appendingPathComponent("memory")
        var taken: [String: Data] = [:]
        for name in (try? manager.contentsOfDirectory(atPath: target.path)) ?? [] where name != "MEMORY.md" {
            taken[name] = manager.contents(atPath: target.appendingPathComponent(name).path) ?? Data()
        }
        var renames: [String: String] = [:]
        for key in keys {
            let memory = claudeProjects.appendingPathComponent(key, isDirectory: true).appendingPathComponent("memory")
            for name in ((try? manager.contentsOfDirectory(atPath: memory.path)) ?? []).sorted() where name != "MEMORY.md" {
                let contents = manager.contents(atPath: memory.appendingPathComponent(name).path) ?? Data()
                guard let existing = taken[name] else {
                    taken[name] = contents
                    continue
                }
                if existing == contents { continue }
                let prefix = Self.origin(of: key, folders: folders)
                var candidate = "\(prefix)-\(name)"
                var number = 2
                while taken[candidate] != nil {
                    candidate = "\(prefix)-\(number)-\(name)"
                    number += 1
                }
                taken[candidate] = contents
                renames["\(key)/memory/\(name)"] = candidate
            }
        }
        return renames
    }

    /// The memories of `keys` in `target`: each file moved (renamed where
    /// its name is taken; dropped where the same file is there), and the
    /// indexes combined, each under the folder it came from, its links to
    /// renamed files following them.
    func mergeMemory(_ keys: [String], folders: [String], into target: URL) throws {
        let manager = FileManager.default
        let sources = keys.map { claudeProjects.appendingPathComponent($0, isDirectory: true).appendingPathComponent("memory") }
            .filter { manager.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return }
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let renames = memoryRenames(keys, folders: folders)
        let targetIndex = target.appendingPathComponent("MEMORY.md")
        let indexes = (manager.fileExists(atPath: targetIndex.path) ? 1 : 0)
            + sources.filter { manager.fileExists(atPath: $0.appendingPathComponent("MEMORY.md").path) }.count
        var combined = (try? String(contentsOf: targetIndex, encoding: .utf8)) ?? ""
        for (key, source) in zip(keys, keys.map { claudeProjects.appendingPathComponent($0).appendingPathComponent("memory") })
        where manager.fileExists(atPath: source.path) {
            var renamed: [String: String] = [:]
            for name in try manager.contentsOfDirectory(atPath: source.path) where name != "MEMORY.md" {
                let file = source.appendingPathComponent(name)
                let newName = renames["\(key)/memory/\(name)"] ?? name
                let destination = target.appendingPathComponent(newName)
                if manager.fileExists(atPath: destination.path) {
                    // The same file already there.
                    try manager.removeItem(at: file)
                } else {
                    try manager.moveItem(at: file, to: destination)
                }
                if newName != name { renamed[name] = newName }
            }
            let index = source.appendingPathComponent("MEMORY.md")
            if var text = try? String(contentsOf: index, encoding: .utf8) {
                for (old, new) in renamed { text = text.replacingOccurrences(of: "(\(old))", with: "(\(new))") }
                if indexes == 1 {
                    combined = text
                } else {
                    let folder = Self.folder(of: key, folders: folders)
                    if !combined.isEmpty, !combined.hasSuffix("\n") { combined += "\n" }
                    combined += (combined.isEmpty ? "" : "\n") + "## From \(folder)\n\n" + text
                }
                try manager.removeItem(at: index)
            }
            if (try? manager.contentsOfDirectory(atPath: source.path))?.isEmpty == true { try manager.removeItem(at: source) }
        }
        if !combined.isEmpty { try combined.write(to: targetIndex, atomically: true, encoding: .utf8) }
    }

    /// The folder a project key was made from, among those moved.
    static func folder(of key: String, folders: [String]) -> String {
        folders.first { claudeKey($0) == key } ?? key
    }

    /// A short name for where a memory came from: its folder's last part,
    /// lowercased ("visor", "developer").
    static func origin(of key: String, folders: [String]) -> String {
        let last = (folder(of: key, folders: folders) as NSString).lastPathComponent
        let cleaned = last.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return cleaned.isEmpty ? "moved" : String(cleaned)
    }

    // MARK: The prompt history and ~/.claude.json

    var historyURL: URL { home.appendingPathComponent(".claude/history.jsonl", isDirectory: false) }
    var claudeConfigURL: URL { home.appendingPathComponent(".claude.json", isDirectory: false) }

    /// The history's line numbers whose project is one of `folders`.
    func historyChanges(_ folders: Set<String>) -> [Int] {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            guard let object = Self.object(line), let project = object["project"] as? String, folders.contains(project) else { return nil }
            return index
        }
    }

    func rewriteHistory(_ folders: Set<String>) throws {
        let text = try String(contentsOf: historyURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard var object = Self.object(line), let project = object["project"] as? String, folders.contains(project) else { return String(line) }
            object["project"] = target
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return String(line) }
            return String(decoding: data, as: UTF8.self)
        }
        try lines.joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)
    }

    /// ~/.claude.json's per-project entries for `folders`.
    func claudeConfigProjects(_ folders: Set<String>) -> [String] {
        guard let data = FileManager.default.contents(atPath: claudeConfigURL.path),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = config["projects"] as? [String: Any] else { return [] }
        return projects.keys.filter { folders.contains($0) }.sorted()
    }

    /// Each entry moved to the target's (the first, in folder order, where
    /// the target has none).
    func rewriteClaudeConfig(_ folders: Set<String>) throws {
        guard let data = FileManager.default.contents(atPath: claudeConfigURL.path),
              var config = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var projects = config["projects"] as? [String: Any] else { return }
        for folder in folders.sorted() {
            guard let entry = projects.removeValue(forKey: folder) else { continue }
            if projects[target] == nil { projects[target] = entry }
        }
        config["projects"] = projects
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: claudeConfigURL, options: .atomic)
    }

    static func object(_ line: Substring) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

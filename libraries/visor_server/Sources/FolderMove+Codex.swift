// Codex's store moved with its sessions: each rollout
// (`~/.codex/sessions/<year>/<month>/<day>/rollout-<time>-<id>.jsonl`) begins
// with its session's meta, whose `cwd` is the folder it ran in. A rollout of
// a moved folder is given the target there; the rest of it is history, as
// it was.

import Foundation

extension FolderMove {
    var codexSessions: URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }

    /// Every rollout, with its first line's folder.
    func codexRollouts() -> [(file: URL, folder: String?)] {
        guard let walker = FileManager.default.enumerator(at: codexSessions, includingPropertiesForKeys: nil) else { return [] }
        var found: [(URL, String?)] = []
        for case let file as URL in walker where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
            found.append((file, Self.metaFolder(Self.firstLine(file))))
        }
        return found.sorted { $0.0.path < $1.0.path }
    }

    /// The rollout of the Codex thread `id` (its name ends in the id).
    func codexRollout(for id: String) -> URL? {
        codexRollouts().first { $0.file.deletingPathExtension().lastPathComponent.hasSuffix(id) }?.file
    }

    func planCodex(_ plan: inout Plan) {
        let folders = Set(plan.folders)
        plan.codexRollouts = codexRollouts().filter { $0.folder.map(folders.contains) ?? false }.map(\.file.path)
    }

    func applyCodex(_ plan: Plan) throws -> [String] {
        for path in plan.codexRollouts {
            let file = URL(fileURLWithPath: path)
            let text = try String(contentsOf: file, encoding: .utf8)
            guard let end = text.firstIndex(of: "\n") ?? Optional(text.endIndex),
                  var meta = Self.object(text[..<end]), var payload = meta["payload"] as? [String: Any] else { continue }
            payload["cwd"] = target
            meta["payload"] = payload
            let line = String(decoding: try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            try (line + text[end...]).write(to: file, atomically: true, encoding: .utf8)
        }
        return plan.codexRollouts.isEmpty ? [] : ["Codex: \(plan.codexRollouts.count) rollouts given \(target)"]
    }

    static func firstLine(_ file: URL) -> Substring {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                bytes.append(chunk[chunk.startIndex..<newline])
                break
            }
            bytes.append(chunk)
        }
        return Substring(String(decoding: bytes, as: UTF8.self))
    }

    /// A session meta line's folder.
    static func metaFolder(_ line: Substring) -> String? {
        guard let object = object(line), object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }
}

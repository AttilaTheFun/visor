// An older build's sessions.json imported again (VisorServer+SessionImport)
// three ways: a session the store and the file both have takes from the
// file only what the older build changed. The base is the file the store
// last imported, kept beside sessions.json (the store's note `importedAs`):
// an older build writes back what it read for every session it didn't
// touch, and that, taken as it is, would undo what this build did since
// (a rename, a turn's rows, a queued message). For each of the session's
// keys, and each of its info's: the file's where it isn't the base's (the
// older build's change, taken: it ran last), else the store's. The queue is
// one key of three (info's `queued`, `queuedImages`, `queuedOrigins`, lined
// up by place): all three the file's, or all three the store's, never mixed.
// With no base to go by (its file gone, or a session it hasn't), the
// store's whole, and said in the log.

import Foundation

extension VisorServer {
    /// The rows an import is to merge in, those the store has made three
    /// ways; one kept as the store has it is left out (the merge leaves a
    /// row it isn't given as it is).
    func reconciled(_ rows: [SessionStore.Row], file: Data?, store: SessionStore, in folder: URL) throws -> [SessionStore.Row] {
        var here: [String: SessionStore.Row] = [:]
        for row in try store.rows() where here[row.id] == nil { here[row.id] = row }
        let theirs = file.map(Self.sessionObjects) ?? [:]
        let baseName = try store.note("importedAs")
        let base = baseName.flatMap { try? Data(contentsOf: folder.appendingPathComponent($0, isDirectory: false)) }.map(Self.sessionObjects)
        if base == nil {
            Self.log("sessions.json is imported again without the file imported before (\(baseName ?? "none noted")): the sessions both have keep the store's")
        }
        var out: [SessionStore.Row] = []
        var kept: [String] = []
        for row in rows {
            guard let mine = here[row.id] else {
                out.append(row)
                continue
            }
            guard let was = base?[row.id], let now = theirs[row.id],
                  let ours = (try? JSONSerialization.jsonObject(with: Data(mine.stored.utf8))) as? [String: Any] else {
                kept.append(row.id)
                continue
            }
            var merged = Self.merged(ours: ours, theirs: now, base: was, within: ["info"], skipping: Self.queueKeys)
            if !Self.same(Self.queue(of: now), Self.queue(of: was)) { Self.takeQueue(of: now, into: &merged) }
            guard let data = try? JSONSerialization.data(withJSONObject: merged),
                  let session = try? JSONDecoder().decode(StoredSession.self, from: data) else {
                kept.append(row.id)
                continue
            }
            out.append(try SessionStore.Row(session, position: row.position))
        }
        if !kept.isEmpty, base != nil {
            Self.log("sessions.json imported again: \(kept.count) session\(kept.count == 1 ? "" : "s") the file imported before hadn't keep the store's (\(kept.joined(separator: ", ")))")
        }
        return out
    }

    /// A file's sessions as JSON objects, by id.
    nonisolated static func sessionObjects(_ data: Data) -> [String: [String: Any]] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [:] }
        var found: [String: [String: Any]] = [:]
        for case let object as [String: Any] in list {
            guard let id = (object["info"] as? [String: Any])?["id"] as? String, found[id] == nil else { continue }
            found[id] = object
        }
        return found
    }

    /// The keys of a session's queue: info's `queued`, and beside it the
    /// files and origins of each (StoredSession), taken together.
    nonisolated static let queueKeys: Set<String> = ["queued", "queuedImages", "queuedOrigins"]

    /// A session's queue, its three keys as one value (none for a key it
    /// hasn't).
    nonisolated static func queue(of session: [String: Any]) -> [Any] {
        [(session["info"] as? [String: Any])?["queued"] ?? NSNull(), session["queuedImages"] ?? NSNull(), session["queuedOrigins"] ?? NSNull()]
    }

    /// The queue of `session`, all three keys, put in `merged`.
    nonisolated static func takeQueue(of session: [String: Any], into merged: inout [String: Any]) {
        var info = merged["info"] as? [String: Any] ?? [:]
        info["queued"] = (session["info"] as? [String: Any])?["queued"]
        merged["info"] = info
        merged["queuedImages"] = session["queuedImages"]
        merged["queuedOrigins"] = session["queuedOrigins"]
    }

    /// `ours`, with each key whose value `theirs` changed from `base`'s
    /// taken from `theirs` (a key gone from theirs, gone), but those of
    /// `skipping`, left as ours; those of `within` merged the same way, a
    /// level down.
    nonisolated static func merged(ours: [String: Any], theirs: [String: Any], base: [String: Any], within: Set<String> = [],
                                   skipping: Set<String> = []) -> [String: Any] {
        var out = ours
        for key in Set(theirs.keys).union(base.keys) where !skipping.contains(key) && !same(theirs[key], base[key]) {
            if within.contains(key), let mine = ours[key] as? [String: Any], let now = theirs[key] as? [String: Any],
               let was = base[key] as? [String: Any] {
                out[key] = merged(ours: mine, theirs: now, base: was, skipping: skipping)
            } else {
                out[key] = theirs[key]
            }
        }
        return out
    }

    /// Whether two JSON values are the same, whatever their keys' order.
    nonisolated static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let write = { (value: Any) in try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) }
        return write(a) == write(b)
    }
}

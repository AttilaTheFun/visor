// sessions.json, the sessions' store before 0.73, read into the server's
// database (server.sqlite, SessionStore) at the first start of a build that
// has one: every session in one transaction, the count read back before
// it's committed. Later starts read the database alone.
//
// sessions.json itself stays where it is, made read-only, for a build of
// 0.72 or before should Visor go back to one (Logan did, 27 Nov; and an
// update that doesn't stay up is rolled back by itself:
// VisorServer+Rollback): it lists the sessions as they were at the import.
// A copy is kept beside it, sessions.json.imported-<day>, written before
// the store notes the import (the next import's base: without it an older
// build's file waits for a start that can write it); its copy of the day
// before (sessions.previous.json) and archive.json (older still) are
// renamed likewise. Nothing is deleted.
//
// An older build that runs writes its own sessions.json, and the next start
// of this one finds the file isn't the one it imported (by its SHA-256,
// which the store notes) and imports it again. Merged, never in place of
// the store: the store is first copied aside whole
// (server.sqlite.before-import-<yyyymmdd-hhmmss>); then a session the
// file and the store both have takes from the file only what the older
// build changed, against the file the store last imported (three ways:
// VisorServer+SessionReimport), its place and its pin kept; each the file
// has that the store hasn't is added; and the sessions the file hasn't
// (made since the import, with all they hold) are left as they are, so
// going back and forth loses nothing. A session ended on the older build
// comes back here; it can be ended again.
//
// A sessions.json that can't be read is left as it is: nothing is
// imported, and nothing written (the store isn't readable, as when the
// file was the store); the next start tries again.
//
// The pins builds of 0.73 before the store kept in messages.sqlite, the
// message cache (its `pins` table, #560), are moved in once too, after
// sessions.json: each session there and not archived is pinned in its row,
// and the store notes it, once the table was read from the cache's file.
// The table is left as it is, and never read again after that.

import Crypto
import Foundation
import MessageCache
import VisorProtocol

extension VisorServer {
    /// The store before server.sqlite: sessions.json, in the data folder.
    static var legacyStoreURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("sessions.json", isDirectory: false) }

    /// The store's note of the SHA-256 of the sessions.json it imported.
    static let importedFingerprintNote = "importedFingerprint"

    /// How the copy of an imported sessions.json is written beside it (the
    /// base of the next import's three ways): a test's may fail.
    static var writeImportedCopy: (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }

    /// sessions.json (and archive.json, from before every session was kept)
    /// read into the store if it's due: never imported, and the store
    /// empty; or imported, and written since by an older build. False when
    /// it was due and couldn't be done: lastError says why, and nothing is
    /// written until a start that can.
    func importLegacyStore(into store: SessionStore, now: Date = Date()) -> Bool {
        let files = FileManager.default
        let folder = Self.storeURL.deletingLastPathComponent()
        let json = Self.legacyStoreURL
        let archive = folder.appendingPathComponent("archive.json", isDirectory: false)
        guard files.fileExists(atPath: json.path) || files.fileExists(atPath: archive.path) else { return true }
        let data = try? Data(contentsOf: json)
        let imported: String?
        do {
            imported = try store.note(Self.importedFingerprintNote)
            if imported == nil, try store.count() > 0 { return true }
        } catch {
            return refuseStore("Could not read \(Self.storeURL.lastPathComponent): \(error). Sessions are not being saved.")
        }
        if let imported {
            // The copy left for a downgrade, unless an older build has
            // written its own over it since.
            guard let data, Self.fingerprint(data) != imported else {
                // Still the one imported: its copy beside it, the next
                // import's base, written if the import couldn't.
                if let data, let name = try? store.note("importedAs"), !name.isEmpty {
                    let copy = folder.appendingPathComponent(name, isDirectory: false)
                    if !files.fileExists(atPath: copy.path), (try? Self.writeImportedCopy(data, copy)) != nil {
                        Self.log("sessions.json copied to \(name), which its import couldn't")
                    }
                }
                return true
            }
            Self.log("sessions.json isn't the one imported: a Visor of 0.72 or before ran here since, and its sessions are merged into the database's")
        } else if data == nil, files.fileExists(atPath: json.path) {
            return refuseStore("Could not read sessions.json. It is left as it is and nothing was imported from it; sessions are not being saved.")
        }
        var sessions: [StoredSession] = []
        for (url, read) in [(json, data), (archive, try? Data(contentsOf: archive))] {
            guard let read, read.count > 2 else { continue }
            do {
                let items = try JSONDecoder().decode([StoredItem].self, from: read)
                // Terminal sessions are gone: one kept by an older build is
                // dropped here, where it would otherwise read as a Claude
                // session (what an agent's name not known here reads as).
                for item in items where item.isTerminal {
                    Self.log("dropped the terminal session \(item.session.info.title) (\(item.session.info.id)): Visor no longer has terminal sessions")
                }
                let kept = items.filter { !$0.isTerminal }.map(\.session)
                sessions += kept.filter { item in !sessions.contains { $0.info.id == item.info.id } }
            } catch {
                // A file we cannot read is not an empty one: this is the
                // whole record of every session, and a decoding change once
                // turned it into "[]".
                return refuseStore("Could not read \(url.lastPathComponent): \(error). It is left as it is and nothing was imported from it; sessions are not being saved.")
            }
        }
        let day = RetiredFiles.day(now)
        let importedName = Self.unusedName("sessions.json.imported-" + day, in: folder)
        // The file copied beside it first: the base the next import goes by,
        // there before the store notes it. Imported again without it, the
        // import waits (the store's notes as they were, so the next start
        // tries again); the first import goes on, and its copy is written at
        // a later start, while sessions.json is still the file imported.
        if let data {
            do {
                try Self.writeImportedCopy(data, folder.appendingPathComponent(importedName, isDirectory: false))
            } catch {
                Self.log("sessions.json couldn't be copied to \(importedName): \(error.localizedDescription)"
                    + (imported == nil ? "" : "; it isn't imported again until it can be"))
                if imported != nil { return true }
            }
        }
        // What the store holds, copied aside before it takes another file in.
        do {
            if try store.count() > 0 {
                let aside = folder.appendingPathComponent(Self.unusedName("\(Self.storeURL.lastPathComponent).before-import-\(Self.backupStamp(now))", in: folder))
                try store.copy(to: aside.path)
                Self.log("\(Self.storeURL.lastPathComponent) copied to \(aside.lastPathComponent) before sessions.json is imported again")
            }
        } catch {
            return refuseStore("Could not copy \(Self.storeURL.lastPathComponent) aside before importing sessions.json: \(error). It is left as it is; sessions are not being saved.")
        }
        let merged: SessionStore.Merged
        do {
            var rows = try sessions.enumerated().map { try SessionStore.Row($1, position: $0) }
            // Again, after an older build: three ways (VisorServer+SessionReimport).
            if imported != nil { rows = try reconciled(rows, file: data, store: store, in: folder) }
            merged = try store.merge(rows, notes: [
                Self.importedFingerprintNote: data.map(Self.fingerprint) ?? "",
                "importedAs": importedName,
                "importedAt": ISO8601DateFormatter().string(from: now),
                "importedCount": String(rows.count),
            ])
        } catch {
            return refuseStore("Could not import sessions.json into \(Self.storeURL.lastPathComponent): \(error). It is left as it is; sessions are not being saved.")
        }
        Self.log("imported \(sessions.count) session\(sessions.count == 1 ? "" : "s") from sessions.json into \(Self.storeURL.lastPathComponent)"
            + (imported == nil ? "" : ": \(merged.updated) brought up to date, \(merged.added) added, \(merged.kept) it hasn't kept as they were"))
        // sessions.json stays, for an older build, read-only (its copy
        // beside it, above), and the other two renamed. Never deleted.
        if data != nil { try? files.setAttributes([.posixPermissions: 0o444], ofItemAtPath: json.path) }
        for name in ["sessions.previous.json", "archive.json"] {
            let url = folder.appendingPathComponent(name, isDirectory: false)
            guard files.fileExists(atPath: url.path) else { continue }
            let renamed = Self.unusedName(name + ".imported-" + day, in: folder)
            do {
                try files.moveItem(at: url, to: folder.appendingPathComponent(renamed, isDirectory: false))
            } catch {
                Self.log("\(name) couldn't be renamed \(renamed): \(error.localizedDescription)")
            }
        }
        return true
    }

    /// The store's note of when messages.sqlite's pins were moved in.
    static let pinsMovedNote = "pinsMovedFromCache"

    /// The pins messages.sqlite kept (ServerCache), moved into the store if
    /// they haven't been: once, whatever there was (none, for a cache that
    /// never had pins), but only once its file was read. A cache in memory
    /// (one that couldn't be opened) or a read that failed moves nothing
    /// and notes nothing: the next start tries again.
    func movePinsFromCache(into store: SessionStore, now: Date = Date()) {
        do {
            guard try store.note(Self.pinsMovedNote) == nil else { return }
            guard let kept = ServerCache.shared.pinnedSessions() else {
                Self.log("the pins messages.sqlite kept couldn't be read (the cache isn't its file, or the read failed): tried again at the next start")
                return
            }
            let pinned = try store.pin(kept, notes: [Self.pinsMovedNote: ISO8601DateFormatter().string(from: now) + " (\(kept.count) kept)"])
            if !kept.isEmpty { Self.log("moved \(pinned) of the \(kept.count) pins messages.sqlite kept into \(Self.storeURL.lastPathComponent)") }
        } catch {
            Self.log("the pins messages.sqlite kept weren't moved into \(Self.storeURL.lastPathComponent): \(error)")
        }
    }

    /// The store isn't read or written this launch, and says why.
    @discardableResult
    func refuseStore(_ why: String) -> Bool {
        storeIsReadable = false
        lastError = why
        Self.log(why)
        return false
    }

    /// `name` in `folder`, or `name-2`, `name-3`… where it's taken.
    static func unusedName(_ name: String, in folder: URL) -> String {
        var candidate = name
        var number = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            number += 1
            candidate = "\(name)-\(number)"
        }
        return candidate
    }

    /// A file's SHA-256, in hex.
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A stored session as sessions.json has it, with its agent's name as
/// written: a name this build does not know reads as Claude in
/// `SessionInfo`, and a terminal session ("shell", kept by 0.18 to 0.31)
/// must be told apart to be dropped instead.
private struct StoredItem: Decodable {
    var session: StoredSession
    var agent: String?

    var isTerminal: Bool { agent == "shell" }

    private enum Keys: String, CodingKey { case info, agent }

    init(from decoder: Decoder) throws {
        session = try StoredSession(from: decoder)
        agent = try decoder.container(keyedBy: Keys.self).nestedContainer(keyedBy: Keys.self, forKey: .info)
            .decodeIfPresent(String.self, forKey: .agent)
    }
}

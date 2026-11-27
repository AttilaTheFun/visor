// sessions.json, the sessions' store before 0.73, read into the server's
// database (server.sqlite, SessionStore) once, at the first start of a
// build that has one: every session in one transaction, the count read
// back before it's committed, and only then the files renamed, never
// deleted: sessions.json to sessions.json.imported-<day>, and
// sessions.previous.json (its copy of the day before) and archive.json
// (older still) likewise. Later starts read the database alone.
//
// What was imported is left at sessions.json too, read-only, for a build
// of 0.72 or before, should Visor go back to one (an update that doesn't
// stay up is rolled back by itself: VisorServer+Rollback): it lists the
// sessions as they were at the import, rather than none. Such a build
// writes its own sessions.json over the copy, and the next start of this
// one finds the file no longer the one it imported (by its SHA-256, which
// the store notes) and imports it again, in place of what the database
// had: the older build ran last, so its sessions are the ones there are.
// The copy goes once no build before 0.73 is to be gone back to.
//
// A sessions.json that can't be read is left as it is: nothing is
// imported, and nothing written (the store isn't readable, as when the
// file was the store); the next start tries again.

import Crypto
import Foundation
import VisorProtocol

extension VisorServer {
    /// The store before server.sqlite: sessions.json, in the data folder.
    static var legacyStoreURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("sessions.json", isDirectory: false) }

    /// The store's note of the SHA-256 of the sessions.json it imported.
    static let importedFingerprintNote = "importedFingerprint"

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
            guard let data, Self.fingerprint(data) != imported else { return true }
            Self.log("sessions.json isn't the one imported: a Visor of 0.72 or before ran here since, and its sessions are imported in place of the database's")
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
        do {
            let rows = try sessions.enumerated().map { try SessionStore.Row($1, position: $0) }
            try store.replaceAll(with: rows, notes: [
                Self.importedFingerprintNote: data.map(Self.fingerprint) ?? "",
                "importedAs": importedName,
                "importedAt": ISO8601DateFormatter().string(from: now),
                "importedCount": String(rows.count),
            ])
        } catch {
            return refuseStore("Could not import sessions.json into \(Self.storeURL.lastPathComponent): \(error). It is left as it is; sessions are not being saved.")
        }
        Self.log("imported \(sessions.count) session\(sessions.count == 1 ? "" : "s") from sessions.json into \(Self.storeURL.lastPathComponent)")
        // Renamed, never deleted.
        var renamed: [(URL, String)] = [(json, importedName)]
        for name in ["sessions.previous.json", "archive.json"] {
            renamed.append((folder.appendingPathComponent(name, isDirectory: false), Self.unusedName(name + ".imported-" + day, in: folder)))
        }
        for (url, name) in renamed where files.fileExists(atPath: url.path) {
            do {
                try files.moveItem(at: url, to: folder.appendingPathComponent(name, isDirectory: false))
            } catch {
                Self.log("\(url.lastPathComponent) couldn't be renamed \(name): \(error.localizedDescription)")
            }
        }
        // The copy for a build of 0.72 or before to read.
        if let data {
            do {
                try data.write(to: json, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o444], ofItemAtPath: json.path)
            } catch {
                Self.log("sessions.json couldn't be left for an older Visor: \(error.localizedDescription)")
            }
        }
        return true
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

// A Super Compact job as it stands (docs/super-compact.md): kept as
// job.json in its folder (`super-compact/<session>/<job>/` in the server's
// data folder) after every step, so a restart picks it up where it was,
// and given as it is by `GET /api/sessions/<id>/super-compact`.

import Foundation

public struct SuperCompactJob: Codable, Equatable, Sendable {
    /// Where it is: the prefilter, the map (Haiku, a chunk at a time), the
    /// merge (Sonnet), the final step (Opus, HANDOFF.md), or ended.
    public enum Phase: String, Codable, Sendable {
        case prefilter, map, merge, final, done, failed, cancelled

        /// Whether it has ended, one way or another.
        public var ended: Bool { self == .done || self == .failed || self == .cancelled }
    }

    /// What it is, as the status answers it.
    public var type = "superCompact"
    public var id: String
    /// The Visor session it compacts, and Claude's conversation id for it.
    public var session: String
    public var conversation: String
    public var title: String
    /// The conversation's file, and the snapshot: its whole lines' bytes
    /// when the job began, which is all the prefilter reads.
    public var source: String
    public var sourceBytes: Int
    /// The job's folder: the chunks, each step's output, HANDOFF.md.
    public var folder: String
    public var phase: Phase = .prefilter
    /// Where it was when it failed or was cancelled: where a failed one
    /// started again carries on from.
    public var failedIn: Phase?
    /// The map: chunks mapped of all of them.
    public var chunk = 0
    public var chunks = 0
    /// The filtered text's size, in characters (UTF-8 bytes).
    public var filteredCharacters = 0
    /// The merge: calls made of all it takes.
    public var mergeStep = 0
    public var mergeSteps = 0
    /// The models and sizes it runs with, as set when it began.
    public var settings: SuperCompactSettings
    /// Why it failed, or the last call that had to be tried again.
    public var error: String?
    /// What the check after the final step found missing in HANDOFF.md.
    public var warnings: [String] = []
    /// HANDOFF.md, once written.
    public var handoff: String?
    /// The session started from HANDOFF.md (the cut-over), once there is
    /// one; and when the person discarded the handoff instead, which ends
    /// its review: nothing is cut over from it then.
    public var continuedAs: String?
    public var discarded: Double?
    /// When it began, last changed and ended (seconds since 1970).
    public var started: Double
    public var updated: Double
    public var finished: Double?

    public init(id: String, session: String, conversation: String, title: String, source: String, sourceBytes: Int, folder: String,
                settings: SuperCompactSettings, now: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.session = session
        self.conversation = conversation
        self.title = title
        self.source = source
        self.sourceBytes = sourceBytes
        self.folder = folder
        self.settings = settings
        started = now
        updated = now
    }

    /// The file it is kept in, in its folder.
    public static let fileName = "job.json"

    public var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }

    /// As kept, or nil when it can't be read.
    public static func kept(in folder: URL) -> SuperCompactJob? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName, isDirectory: false)) else { return nil }
        return try? JSONDecoder().decode(SuperCompactJob.self, from: data)
    }

    /// Done and waiting for the person's review: neither cut over nor
    /// discarded.
    public var awaitsReview: Bool { phase == .done && continuedAs == nil && discarded == nil }

    /// Written to its folder, whole or not at all.
    public func keep() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        Self.makePrivate(folderURL)
        try? data.write(to: folderURL.appendingPathComponent(Self.fileName, isDirectory: false), options: .atomic)
    }

    /// A folder made, or made again, its owner's alone (0700): a job's
    /// folders hold the conversation's text, prefiltered, and the first
    /// lines of its tools' results can carry tokens. Set after it is made
    /// too, for one that was there already.
    public static func makePrivate(_ folder: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// As the status answers.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

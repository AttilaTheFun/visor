import Foundation
import VisorProtocol
import VisorServices

/// Answers as a server would, from the fixtures, at once. The transcript's
/// sync, once it has the rows, is held for as long as it is asked, as a
/// server holds it while nothing changes. Anything that would change
/// something is taken, and nothing changes. What it answers with goes
/// through the wire's own coding first (`wire`), as a server's answer
/// does: a screenshot of the fixture is then a run of the decoders too, on
/// whatever platform it is taken. (One setting is kept, for its switch:
/// a session's notifications.)
final class FixtureAgentServer: AgentServer {
    private var onEvent: (@MainActor (AgentServerEvent) -> Void)?

    func authenticate(_ record: AgentServerRecord) async throws -> String? { VisorFixture.record.name }

    /// An envelope as it arrives: encoded and decoded again.
    static func wire(_ envelope: Envelope) -> Envelope {
        Envelope.decode(envelope.encoded()) ?? envelope
    }

    /// The fixture's sessions and catalogs, as a `welcome` carries them.
    static var welcome: Envelope {
        wire(Envelope.welcome(host: VisorFixture.record.name, sessions: VisorFixture.sessions, catalogs: VisorFixture.catalogs))
    }

    func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void) {
        self.onEvent = onEvent
        let welcome = Self.welcome
        Task {
            onEvent(.welcome(name: welcome.host ?? "", sessions: welcome.sessions ?? [], catalogs: welcome.catalogs ?? []))
        }
    }

    func closeChannel() { onEvent = nil }

    func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    func unsubscribe(_ session: String) {}

    /// The sign-in-code screen's sign-in has had its code: it waits no more.
    private var signedIn = false

    /// A sign-in's code, taken as a server takes it: the sign-in ends, and
    /// the session is told so — here with the code it was given, so a test
    /// sees what reached the sign-in, and by which way (a message for the
    /// agent goes nowhere in the fixture).
    func signIn(_ session: String, code: String) {
        guard let onEvent else { return }
        signedIn = true
        let reply = Self.wire(.ephemeral(session: session, streams: [], status: [], activity: nil, busy: false,
                                         approval: nil, queued: [], notice: "Signed in to Claude again with the code \(code).",
                                         signIn: nil))
        Task { onEvent(.session(reply)) }
    }

    func subscribe(_ session: String) {
        guard let onEvent else { return }
        // The chat waits on a tool call; on the question screen, on a
        // question; on the sign-in-code screen, on Claude's sign-in.
        let signingIn = session == VisorFixture.chatSession && VisorFixture.screen == "sign-in-code" && !signedIn
        let approval: ApprovalRequest? = session != VisorFixture.chatSession || signingIn ? nil
            : VisorFixture.screen == "question" ? VisorFixture.question
            : ApprovalRequest(id: "fixture-approval", tool: "Bash", summary: "swift test --filter SyncTests")
        let reply = Self.wire(.ephemeral(session: session, streams: [], status: [], activity: nil, busy: false,
                                         approval: approval, queued: [], notice: nil,
                                         signIn: signingIn ? VisorFixture.signInPage : nil))
        Task { onEvent(.session(reply)) }
    }

    func acknowledge(_ session: String) {}
    /// On the `earlier` screen, the goal session's thread goes back further:
    /// a page of 200 rows comes half a second after it is asked for, as
    /// from a server, and there is nothing before those.
    func loadEarlier(_ session: String, before: String) {
        guard let onEvent, VisorFixture.screen == "earlier", session == VisorFixture.goalSession else { return }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            var page = Envelope(type: "earlier")
            page.session = session
            page.entries = (0..<200).map { index in
                TranscriptEntry(id: "\(session)-earlier-\(index)", role: index % 2 == 0 ? .user : .assistant, text: "Earlier row \(index)")
            }
            page.more = false
            onEvent(.session(Self.wire(page)))
        }
    }

    /// The sessions whose notifications were switched off here: the one
    /// setting the fixture keeps, as a server keeps it, so its switch in
    /// Session details stays where it was put.
    private var muted: Set<String> = []

    /// The fixture's sessions, with what was switched here.
    private func kept(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.map { info in
            var info = info
            info.notifications = !muted.contains(info.id)
            return info
        }
    }

    func sessions() async throws -> [SessionInfo] { kept((Self.welcome.sessions ?? []) + restored) }
    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo] { [] }
    func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo] {
        guard case .notifications(let on) = action else { return [] }
        if on { muted.remove(session) } else { muted.insert(session) }
        return kept(Self.welcome.sessions ?? []).filter { $0.id == session }.map { Self.wire(.sessions([$0])).sessions?.first ?? $0 }
    }
    func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo] { [] }

    func transcript(of session: String, since revision: Int, generation: Int, after: String?) async throws -> Envelope {
        if revision == 1, VisorFixture.screen == "learns-earlier", session == VisorFixture.chatSession {
            // The held sync answered ten seconds on with no row changed but
            // word of earlier rows, as a server's first answer after a
            // launch can (often the one to a send): the thread must not
            // move for it.
            try await Task.sleep(nanoseconds: 10_000_000_000)
            var e = Envelope.transcript(session: session, entries: [], streaming: "", activity: nil, busy: false, error: nil)
            e.revision = 2
            e.generation = 1
            e.more = true
            return Self.wire(e)
        }
        if VisorFixture.screen == "torrent", session == VisorFixture.chatSession, (1...40).contains(revision) {
            // A reply pouring in: four seconds after the chat opens, a row
            // every quarter second for ten seconds, each after the last.
            try await Task.sleep(nanoseconds: revision == 1 ? 4_000_000_000 : 250_000_000)
            let row = TranscriptEntry(id: "torrent-\(revision)", role: .assistant,
                                      text: "Row \(revision) of the reply: the sync queue drained another batch of offline rows, "
                                          + "checked each against the server's copy, and moved on to the next.")
            var e = Envelope.transcript(session: session, entries: [row], streaming: "", activity: nil, busy: false, error: nil)
            e.after = [revision == 1 ? VisorFixture.transcript.last?.id ?? "" : "torrent-\(revision - 1)"]
            e.revision = revision + 1
            e.generation = 1
            return Self.wire(e)
        }
        if VisorFixture.screen == "arrivals", session == VisorFixture.chatSession, revision == 1 || revision == 2 {
            // Rows come in as a reply would: two twelve seconds on, one
            // more fourteen seconds after, each after the last there was.
            // (The pill stays until tapped here: `newRowsPillSeconds`.)
            // With a `goFile`, the first two come a second after it does.
            let go = VisorFixture.goFile
            if revision == 1, !go.isEmpty {
                while !FileManager.default.fileExists(atPath: go) { try await Task.sleep(nanoseconds: 250_000_000) }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } else {
                try await Task.sleep(nanoseconds: revision == 1 ? 12_000_000_000 : 14_000_000_000)
            }
            let rows = revision == 1
                ? [TranscriptEntry(id: "arrival-1", role: .user, text: "Run them now, please."),
                   TranscriptEntry(id: "arrival-2", role: .assistant, text: "Running the sync tests now.")]
                : [TranscriptEntry(id: "arrival-3", role: .assistant, text: "All 42 sync tests pass, offline rows included.")]
            var e = Envelope.transcript(session: session, entries: rows, streaming: "", activity: nil, busy: false, error: nil)
            e.after = revision == 1 ? [VisorFixture.transcript.last?.id ?? "", "arrival-1"] : ["arrival-2"]
            e.revision = revision + 1
            e.generation = 1
            return Self.wire(e)
        }
        if VisorFixture.screen == "burst", session == VisorFixture.chatSession, revision == 1 {
            // A burst of long rows at once, as a reply that ran on while
            // the app was away comes in when it is back: more than a
            // screen of them, taller than the list guesses before it has
            // measured them.
            try await Task.sleep(nanoseconds: 8_000_000_000)
            let paragraph = "The retry queue now keeps each row's last edit, so a row changed twice while offline reaches the server once, as it was last written, and the banner says how many are still waiting."
            let rows = (1...8).map { n in
                TranscriptEntry(id: "burst-\(n)", role: .assistant,
                                text: n == 8 ? "Burst done: every row is on the server."
                                    : "Step \(n).\n\n\(paragraph)\n\n```swift\nfunc retry(_ row: Row) async throws {\n    try await server.save(row)\n    store.markSent(row.id)\n}\n```\n\n\(paragraph)")
            }
            var e = Envelope.transcript(session: session, entries: rows, streaming: "", activity: nil, busy: false, error: nil)
            e.after = [VisorFixture.transcript.last?.id ?? ""] + (1..<8).map { "burst-\($0)" }
            e.revision = 2
            e.generation = 1
            return Self.wire(e)
        }
        if revision >= 1 {
            // Up to date: held, as a server holds it, until asked to stop.
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 60_000_000_000) }
            throw CancellationError()
        }
        let rows = session == VisorFixture.chatSession ? VisorFixture.transcript
            : [TranscriptEntry(id: session + "-1", role: .user, text: "Start on this."),
               TranscriptEntry(id: session + "-2", role: .assistant, text: VisorFixture.sessions.first { $0.id == session }?.preview ?? "")]
        var e = Envelope.transcript(session: session, entries: rows, streaming: "", activity: nil, busy: false, error: nil)
        e.revision = 1
        e.generation = 1
        e.reset = true
        e.more = VisorFixture.screen == "earlier" && session == VisorFixture.goalSession
        return Self.wire(e)
    }

    func commands(for session: String) async throws -> [SlashCommand] {
        [SlashCommand(name: "compact", description: "Summarize the conversation so far"),
         SlashCommand(name: "goal", description: "Keep working until a condition is met")]
    }

    func resumable(agent: AgentKind, cwd: String) async throws -> [ResumableSession] { [] }
    func relocateSessions(from cwd: String, to destination: String) async throws -> [SessionInfo] { [] }

    func folders(at path: String) async throws -> FolderListing { FolderListing(path: path, folders: []) }
    func makeFolder(_ path: String) async throws -> String { path }
    func fileData(path: String) async throws -> String { VisorFixture.picture }
    func upload(base64: String, name: String) async throws -> String { VisorFixture.picturePath }

    func search(_ query: String) async throws -> [SearchHit] {
        [SearchHit(session: VisorFixture.chatSession, message: "f9", role: "assistant", snippet: "Rows now sync in the background…",
                   title: "Offline sync", cwd: "/Users/visor/Developer/weather")]
    }

    // MARK: Session archives

    /// The sessions restored here from VisorFixture.backups, listed from
    /// then on as a server lists a session it started again.
    private var restored: [SessionInfo] = []

    var archives: Bool { true }

    func backups() async throws -> [SessionBackup] { VisorFixture.backups.map { SessionBackup(json: $0.json) ?? $0 } }

    /// A session of one of VisorFixture.backups put back as a server puts
    /// it back: refused while it is here when imported, else restored.
    func restore(_ path: String, sessions ids: [String]?) async throws -> (backup: SessionBackup, sessions: [SessionInfo]) {
        guard var backup = VisorFixture.backups.first(where: { $0.path == path }) else { throw AgentServerError.message("No such backup") }
        let here = Set(((Self.welcome.sessions ?? []) + restored).map(\.id))
        backup.sessions = backup.sessions.filter { ids?.contains($0.id) ?? true }.map { item in
            var item = item
            if here.contains(item.id) {
                item.outcome = backup.imported ? "Not restored: “\(item.title)” (\(item.id)) is on this computer already. Remove it first, then restore it."
                    : "Here already: left as it is."
            } else {
                item.outcome = "Restored."
                restored.append(SessionInfo(id: item.id, agent: .claude, cwd: VisorFixture.restoredFolder, title: item.title, created: VisorFixture.now))
            }
            return item
        }
        return (backup, kept((Self.welcome.sessions ?? []) + restored))
    }

    /// An export: the session's name and a small archive's bytes.
    func exportSession(_ session: String) async throws -> (token: String, file: MigrationFile) {
        let title = VisorFixture.sessions.first { $0.id == session }?.title ?? "Session"
        return (session, MigrationFile(id: "archive", place: "\(title)-2026-11-20.visorsession", size: VisorFixture.archive.count, packed: true))
    }

    func migrationRead(_ offer: String, file: String, offset: Int, length: Int) async throws -> (data: String, next: Int) {
        let bytes = VisorFixture.archive
        let end = min(bytes.count, offset + length)
        return (bytes[min(offset, end)..<end].base64EncodedString(), end)
    }

    /// An import: taken, and kept as VisorFixture's imported backup.
    func importUpload(size: Int, name: String) async throws -> String { "fixture-import" }
    func importWrite(_ token: String, offset: Int, data: String) async throws -> Int { offset + (Data(base64Encoded: data)?.count ?? 0) }
    func importFinish(_ token: String) async throws -> SessionBackup { VisorFixture.backups[0] }
}

import VisorProtocol
import VisorServices

/// Answers as a server would, from the fixtures, at once. The transcript's
/// sync, once it has the rows, is held for as long as it is asked, as a
/// server holds it while nothing changes. Anything that would change
/// something is taken, and nothing changes. What it answers with goes
/// through the wire's own coding first (`wire`), as a server's answer
/// does: a screenshot of the fixture is then a run of the decoders too, on
/// whatever platform it is taken.
final class FixtureAgentServer: AgentServer {
    private var onEvent: (@MainActor (AgentServerEvent) -> Void)?

    func authenticate(_ record: AgentServerRecord) async throws -> String? { VisorFixture.record.name }

    /// An envelope as it arrives: encoded and decoded again.
    static func wire(_ envelope: Envelope) -> Envelope {
        Envelope.decode(envelope.encoded()) ?? envelope
    }

    /// The fixture's sessions and catalogs, as a `welcome` carries them,
    /// from a computer that runs agents in containers too (New Session's
    /// Runs).
    static var welcome: Envelope {
        var welcome = Envelope.welcome(host: VisorFixture.record.name, sessions: VisorFixture.sessions, catalogs: VisorFixture.catalogs)
        welcome.container = true
        return wire(welcome)
    }

    func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void) {
        self.onEvent = onEvent
        let welcome = Self.welcome
        Task {
            onEvent(.welcome(name: welcome.host ?? "", sessions: welcome.sessions ?? [], catalogs: welcome.catalogs ?? [],
                             containers: welcome.container == true))
        }
    }

    func closeChannel() { onEvent = nil }

    func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    func unsubscribe(_ session: String) {}
    func signIn(_ session: String, code: String) {}

    func subscribe(_ session: String) {
        guard let onEvent else { return }
        // The chat waits on a tool call; on the question screen, on a question.
        let approval: ApprovalRequest? = session != VisorFixture.chatSession || VisorFixture.screen == "long" ? nil
            : VisorFixture.screen == "question" ? VisorFixture.question
            : ApprovalRequest(id: "fixture-approval", tool: "Bash", summary: "swift test --filter SyncTests")
        let reply = Self.wire(.ephemeral(session: session, streams: [], status: [], activity: nil, busy: false,
                                         approval: approval, queued: [], notice: nil))
        Task { onEvent(.session(reply)) }
    }

    func acknowledge(_ session: String) {}
    /// On the `earlier` screen, the goal session's thread goes back further:
    /// a page of 200 rows comes half a second after it is asked for, as
    /// from a server, and there is nothing before those.
    func loadEarlier(_ session: String, before: String) {
        if VisorFixture.screen == "long", session == VisorFixture.chatSession { return loadEarlierLong(before: before) }
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

    /// On the `long` screen, the chat's rows before one, a page of 100 a
    /// moment after they are asked for, as from a server.
    private func loadEarlierLong(before: String) {
        guard let onEvent, let end = Int(before.dropFirst("fixture-long-".count)) else { return }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            var page = Envelope(type: "earlier")
            page.session = VisorFixture.chatSession
            page.entries = (max(0, end - 100)..<end).map(VisorFixture.longRow)
            page.more = end > 100
            onEvent(.session(Self.wire(page)))
        }
    }

    func sessions() async throws -> [SessionInfo] { Self.welcome.sessions ?? [] }
    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo] { [] }
    func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo] { [] }
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
            try await Task.sleep(nanoseconds: revision == 1 ? 12_000_000_000 : 14_000_000_000)
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
        let long = VisorFixture.screen == "long" && session == VisorFixture.chatSession
        let rows = long ? (VisorFixture.longRows - 100..<VisorFixture.longRows).map(VisorFixture.longRow)
            : session == VisorFixture.chatSession ? VisorFixture.transcript
            : [TranscriptEntry(id: session + "-1", role: .user, text: "Start on this."),
               TranscriptEntry(id: session + "-2", role: .assistant, text: VisorFixture.sessions.first { $0.id == session }?.preview ?? "")]
        var e = Envelope.transcript(session: session, entries: rows, streaming: "", activity: nil, busy: false, error: nil)
        e.revision = 1
        e.generation = 1
        e.reset = true
        e.more = long || (VisorFixture.screen == "earlier" && session == VisorFixture.goalSession)
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
}

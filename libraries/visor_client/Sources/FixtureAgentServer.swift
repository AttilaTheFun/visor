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

    /// The fixture's sessions and catalogs, as a `welcome` carries them.
    static var welcome: Envelope {
        wire(.welcome(host: VisorFixture.record.name, sessions: VisorFixture.sessions, catalogs: VisorFixture.catalogs))
    }

    func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void) {
        self.onEvent = onEvent
        let welcome = Self.welcome
        Task { onEvent(.welcome(name: welcome.host ?? "", sessions: welcome.sessions ?? [], catalogs: welcome.catalogs ?? [])) }
    }

    func closeChannel() { onEvent = nil }

    func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    func subscribe(_ session: String) {
        guard let onEvent else { return }
        let approval = session == VisorFixture.chatSession
            ? ApprovalRequest(id: "fixture-approval", tool: "Bash", summary: "swift test --filter SyncTests") : nil
        let reply = Self.wire(.ephemeral(session: session, streams: [], status: [], activity: nil, busy: false,
                                         approval: approval, queued: [], notice: nil))
        Task { onEvent(.session(reply)) }
    }

    func assumeControl(_ session: String, cols: Int, rows: Int) {}
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
    func sendInput(_ session: String, data: String) {}
    func resize(_ session: String, cols: Int, rows: Int) {}

    func sessions() async throws -> [SessionInfo] { Self.welcome.sessions ?? [] }
    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo] { [] }
    func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo] { [] }
    func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo] { [] }

    func transcript(of session: String, since revision: Int, generation: Int) async throws -> Envelope {
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
        if VisorFixture.screen == "arrivals", session == VisorFixture.chatSession, revision == 1 || revision == 2 {
            // Rows come in as a reply would: two twelve seconds on, one
            // more eight seconds after, each after the last there was.
            try await Task.sleep(nanoseconds: revision == 1 ? 12_000_000_000 : 8_000_000_000)
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
}

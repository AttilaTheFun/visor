import VisorProtocol
import VisorServices

/// Answers as a server would, from the fixtures, at once. The transcript's
/// sync, once it has the rows, is held for as long as it is asked, as a
/// server holds it while nothing changes. Anything that would change
/// something is taken, and nothing changes.
final class FixtureAgentServer: AgentServer {
    private var onEvent: (@MainActor (AgentServerEvent) -> Void)?

    func authenticate(_ record: AgentServerRecord) async throws -> String? { VisorFixture.record.name }

    func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void) {
        self.onEvent = onEvent
        Task { onEvent(.welcome(name: VisorFixture.record.name, sessions: VisorFixture.sessions, catalogs: VisorFixture.catalogs)) }
    }

    func closeChannel() { onEvent = nil }

    func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    func subscribe(_ session: String) {
        guard let onEvent else { return }
        let approval = session == VisorFixture.chatSession
            ? ApprovalRequest(id: "fixture-approval", tool: "Bash", summary: "swift test --filter SyncTests") : nil
        let reply = Envelope.ephemeral(session: session, streams: [], status: [], activity: nil, busy: false,
                                       approval: approval, queued: [], notice: nil)
        Task { onEvent(.session(reply)) }
    }

    func assumeControl(_ session: String, cols: Int, rows: Int) {}
    func returnToChat(_ session: String) {}
    func acknowledge(_ session: String) {}
    func loadEarlier(_ session: String, before: String) {}
    func sendInput(_ session: String, data: String) {}
    func resize(_ session: String, cols: Int, rows: Int) {}

    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo] { [] }
    func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo] { [] }
    func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo] { [] }

    func transcript(of session: String, since revision: Int, generation: Int) async throws -> Envelope {
        if revision == 1 {
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
        e.more = false
        return e
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

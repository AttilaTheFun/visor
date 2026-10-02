import VisorProtocol
import VisorServices

/// Answers as a server would, from the fixtures, at once. The transcript's
/// sync, once it has the rows, is held for as long as it is asked, as a
/// server holds it while nothing changes.
final class FixtureTransport: HostTransport {
    private var onEvent: (@MainActor (TransportEvent) -> Void)?

    func connect(_ config: HostConfig, onEvent: @escaping @MainActor (TransportEvent) -> Void) {
        self.onEvent = onEvent
        Task { onEvent(.opened) }
    }

    func send(_ text: String) {
        guard let envelope = Envelope.decode(text), let onEvent else { return }
        var replies: [Envelope] = []
        switch envelope.type {
        case "login":
            replies.append(.welcome(host: VisorFixture.config.name, sessions: VisorFixture.sessions, catalogs: VisorFixture.catalogs))
        case "subscribe":
            guard let id = envelope.session else { return }
            let approval = id == VisorFixture.chatSession
                ? ApprovalRequest(id: "fixture-approval", tool: "Bash", summary: "swift test --filter SyncTests") : nil
            replies.append(.ephemeral(session: id, streams: [], status: [], activity: nil, busy: false,
                                      approval: approval, queued: [], notice: nil))
        default:
            return
        }
        Task { for reply in replies { onEvent(.message(reply.encoded())) } }
    }

    func disconnect() { onEvent = nil }

    func call(_ method: String, _ path: String, body: String, config: HostConfig) async throws -> String {
        let route = path.split(separator: "?").first.map(String.init) ?? path
        let parts = route.split(separator: "/").map(String.init)
        if route == "/hello" { return Envelope.hello(host: VisorFixture.config.name, login: "snapshot@example.com", token: "fixture").encoded() }
        if parts.count == 3, parts[0] == "sessions", parts[2] == "transcript" {
            let held = path.contains("since=1&")
            if held {
                // Up to date: held, as a server holds it, until asked to stop.
                while !Task.isCancelled { try await Task.sleep(nanoseconds: 60_000_000_000) }
                throw CancellationError()
            }
            let rows = parts[1] == VisorFixture.chatSession ? VisorFixture.transcript
                : [TranscriptEntry(id: parts[1] + "-1", role: .user, text: "Start on this."),
                   TranscriptEntry(id: parts[1] + "-2", role: .assistant, text: VisorFixture.sessions.first { $0.id == parts[1] }?.preview ?? "")]
            var e = Envelope.transcript(session: parts[1], entries: rows, streaming: "", activity: nil, busy: false, error: nil)
            e.revision = 1
            e.generation = 1
            e.reset = true
            e.more = false
            return e.encoded()
        }
        if parts.count == 3, parts[0] == "sessions", parts[2] == "commands" {
            var e = Envelope(type: "commands")
            e.commands = [SlashCommand(name: "compact", description: "Summarize the conversation so far"),
                          SlashCommand(name: "goal", description: "Keep working until a condition is met")]
            return e.encoded()
        }
        if route == "/file" {
            var e = Envelope(type: "file")
            e.path = VisorFixture.picturePath
            e.text = VisorFixture.picture
            return e.encoded()
        }
        if route == "/search" {
            let hit: [String: JSONValue] = ["session": .string(VisorFixture.chatSession), "id": .string("f9"), "role": .string("assistant"),
                                            "snippet": .string("Rows now sync in the background…"), "title": .string("Offline sync"),
                                            "cwd": .string("/Users/visor/Developer/weather")]
            return JSONValue.object(["type": .string("search"), "query": .string(VisorFixture.searchQuery), "hits": .array([.object(hit)])]).encoded()
        }
        if route == "/folders" || route == "/resumable" {
            var e = Envelope(type: route == "/folders" ? "folders" : "resumable")
            e.folders = []
            e.resumable = []
            e.exists = true
            return e.encoded()
        }
        // Anything that would change something: taken, and nothing changes.
        return Envelope(type: "reply").encoded()
    }

    func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}

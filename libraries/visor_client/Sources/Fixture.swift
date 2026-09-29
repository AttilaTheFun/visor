// A computer that is not there: canned sessions and a canned transcript,
// the same every time, for screenshot tests. The setting `fixture` =
// "snapshot" (on Apple `visor.fixture` in UserDefaults, which the launch
// argument `-visor.fixture snapshot` sets) makes the store show only
// this computer; `fixture.screen` names the screen to open on. The app
// above the transport runs as it always does: the hello, the socket's
// login and welcome, the transcript's sync, the files and the search are
// all answered here, from these fixtures, instead of by a server.

import VisorProtocol
import VisorServices

public enum VisorFixture {
    /// Whether the app is showing the canned computer.
    public static var active: Bool { VisorHost.settings?.get(key: "fixture") == "snapshot" }
    /// The screen to open on: sessions, chat, goal, inspector, models,
    /// search or connect ("" for the app's own first screen).
    public static var screen: String { active ? (VisorHost.settings?.get(key: "fixture.screen") ?? "") : "" }

    public static let hostID = "fixture"
    /// The session a screen that shows one opens.
    public static let chatSession = "fixture-chat"
    /// The session the `goal` screen opens: working toward a goal and
    /// looping, with nothing waiting for approval, so the composer shows
    /// both pills.
    public static let goalSession = "fixture-docs"
    /// The words the search screen searches for.
    public static let searchQuery = "sync"

    static let config = HostConfig(id: hostID, name: "Snapshot Mac", host: "snapshot.local", password: "", everConnected: true,
                                   backend: FixtureBackend.name)

    /// A small picture, the same bytes every run: four coloured blocks.
    static let picture = "iVBORw0KGgoAAAANSUhEUgAAAGAAAABACAIAAABqVuVZAAAAfklEQVR42u3QAQkAIAwAsIcyi2gVe5jJBta5NS4MlmAx+i2lnVlKCBIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIECRL0cVDuWmJlLYIECRIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIE/Rv0AH3IYA5oDZ+mAAAAAElFTkSuQmCC"
    static let picturePath = "/Users/visor/Pictures/layout.png"
    static let now: Double = 1_790_000_000

    static var sessions: [SessionInfo] {
        func session(_ id: String, _ agent: AgentKind, _ cwd: String, _ title: String, model: String, preview: String,
                     busy: Bool = false, age: Double) -> SessionInfo {
            var info = SessionInfo(id: id, agent: agent, cwd: cwd, title: title, busy: busy, model: model, created: now - age - 3600)
            info.preview = preview
            info.updated = now - age
            // What ran is what was chosen: no fallback shown.
            info.reportedModel = nil
            info.contextUsed = 48_000
            info.contextLimit = 200_000
            return info
        }
        var chat = session(chatSession, .claude, "/Users/visor/Developer/weather", "Offline sync",
                           model: "opus", preview: "Rows now sync in the background; waiting for your approval to run the tests.", age: 60)
        chat.goal = "Rows written offline are all on the server after reconnecting"
        var docs = session("fixture-docs", .claude, "/Users/visor/Developer/handbook", "Release notes",
                           model: "sonnet", preview: "Drafted the notes for 2.4 with the three fixes.", age: 7200)
        docs.goal = "The release notes cover every change since 2.3"
        docs.loopCron = "*/30 * * * *"
        return [
            chat,
            session("fixture-busy", .codex, "/Users/visor/Developer/weather", "Widget layout",
                    model: "gpt-5.5", preview: "Laying out the medium widget.", busy: true, age: 300),
            docs,
            session("fixture-api", .codex, "/Users/visor/Developer/api", "Rate limits",
                    model: "gpt-5.5", preview: "The limiter now allows bursts of 20 per minute.", age: 86_400),
        ]
    }

    static var catalogs: [AgentCatalog] {
        [AgentCatalog(agent: .claude, models: [
            AgentModel(id: "opus", title: "Opus 5.5", subtitle: "Most capable", efforts: ["low", "medium", "high"], defaultEffort: "high"),
            AgentModel(id: "sonnet", title: "Sonnet 5", subtitle: "Fast and capable", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
            AgentModel(id: "haiku", title: "Haiku 4.5", subtitle: "Fastest", efforts: []),
         ], defaultModel: "opus"),
         AgentCatalog(agent: .codex, models: [
            AgentModel(id: "gpt-5.5", title: "GPT-5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
         ], defaultModel: "gpt-5.5")]
    }

    static let transcript: [TranscriptEntry] = [
        TranscriptEntry(id: "f1", role: .user, text: "The weather app loses rows when the phone goes offline. Can you make the sync survive that?"),
        TranscriptEntry(id: "f2", role: .assistant, text: "I'll look at how rows are written first.", activities: ["Read: Sources/Sync/RowStore.swift", "Grep: saveRows"]),
        TranscriptEntry(id: "f3", role: .tool, text: "No matches outside RowStore.", toolName: "tool_result"),
        TranscriptEntry(id: "f4", role: .assistant, text: """
        Found it. **Rows are written only after the network call succeeds**, so anything fetched while offline is dropped.

        The fix:
        - write each row to the local store first
        - mark it *pending* until the server confirms it
        - retry pending rows when the connection returns

        ```swift
        func save(_ row: Row) throws {
            try store.insert(row, state: .pending)
            queue.enqueue(row.id)
        }
        ```

        See [the sync notes](https://example.com/sync) for the retry rules.
        """),
        TranscriptEntry(id: "f5", role: .user, text: "Here's the layout I want for the offline banner.", images: [picturePath],
                        imageSizes: [ImageSize(width: 96, height: 64)]),
        TranscriptEntry(id: "f6", role: .user, text: "/goal Rows written offline are all on the server after reconnecting"),
        TranscriptEntry(id: "f7", role: .tool, text: "Rows written offline are all on the server after reconnecting", toolName: "goal"),
        TranscriptEntry(id: "f8", role: .assistant, text: "", activities: ["Edit: Sources/Sync/RowStore.swift", "Edit: Sources/Sync/SyncQueue.swift", "Bash: swift build"]),
        TranscriptEntry(id: "f9", role: .assistant, text: "Rows now sync in the background, and the banner matches your layout. I'd like to run the tests next."),
    ]
}

/// The canned computer's road.
public struct FixtureBackend: Backend {
    public static let name = "fixture"
    public let id = FixtureBackend.name
    public let title = "Snapshot"
    public let hostFieldTitle = "Host"
    public let hostPlaceholder = "snapshot.local"
    public let passwordFieldTitle = "Password"
    public let help = "Canned data for screenshot tests."
    public init() {}
    public func makeTransport() -> any HostTransport { FixtureTransport() }
}

/// Answers as a server would, from the fixtures, at once. The transcript's
/// sync, once it has the rows, is held for as long as it is asked, as a
/// server holds it while nothing changes.
final class FixtureTransport: HostTransport {
    private var onEvent: (@MainActor (TransportEvent) -> Void)?

    func connect(_ config: HostConfig, onEvent: @escaping @MainActor (TransportEvent) -> Void) {
        self.onEvent = onEvent
        Task { @MainActor in onEvent(.opened) }
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
        Task { @MainActor in for reply in replies { onEvent(.message(reply.encoded())) } }
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

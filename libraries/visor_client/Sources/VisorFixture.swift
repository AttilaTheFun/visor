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
    @MainActor public static var active: Bool { VisorHost.settings?.get(key: "fixture") == "snapshot" }
    /// The screen to open on: sessions, chat, goal, inspector, models,
    /// search or connect ("" for the app's own first screen).
    @MainActor public static var screen: String { active ? (VisorHost.settings?.get(key: "fixture.screen") ?? "") : "" }

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

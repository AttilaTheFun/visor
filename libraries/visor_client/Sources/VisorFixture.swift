// A computer that is not there: canned sessions and a canned transcript,
// the same every time, for screenshot tests. The setting `fixture` =
// "snapshot" (on Apple `visor.fixture` in UserDefaults, which the launch
// argument `-visor.fixture snapshot` sets) makes the store show only
// this computer; `fixture.screen` names the screen to open on. The app
// above the transport runs as it always does: the hello, the socket's
// login and welcome, the transcript's sync, the files and the search are
// all answered here, from these fixtures, instead of by a server.

import Foundation
import VisorProtocol
import VisorServices

public enum VisorFixture {
    /// Whether the app is showing the canned computer.
    @MainActor public static var active: Bool { VisorHost.settings?.get(key: "fixture") == "snapshot" }
    /// The screen to open on: sessions, chat, question, goal, inspector,
    /// models, search, connect, new-session or commands (the chat
    /// with "/" in its composer, its slash commands offered),
    /// sign-in-code (the chat, its Claude Code waiting on a sign-in:
    /// `signInPage`) ("" for the app's own first screen); also earlier
    /// (a page of earlier rows goes in), learns-earlier (the chat, told
    /// ten seconds on that there are rows before it), arrivals (the
    /// chat, with rows coming in twelve and twenty-six seconds on, or
    /// from `goFile`'s coming) and
    /// burst (eight long rows at once, eight seconds on),
    /// turn (the chat with a turn going through its states, then its
    /// reply's row: `turnSteps`), turn-tool, turn-subagents and
    /// turn-background (the chat held in one state: `stillTurn`),
    /// and super-compact-running, -review and -done (Super Compact's
    /// sheet over the chat: its job running, done for review, cut over).
    /// A session to open a few seconds after launch, for a recording of
    /// its first open (`-visor.probe.open <session id>`); "" for none.
    @MainActor public static var probeSession: String { VisorHost.settings?.get(key: "probe.open") ?? "" }
    @MainActor public static var screen: String { active ? (VisorHost.settings?.get(key: "fixture.screen") ?? "") : "" }
    /// A file whose coming starts the arrivals screen's rows, a second
    /// later, in place of its clock (`-visor.fixture.go <path>`): a test
    /// makes it once it is up the thread, so a slow simulator can't have
    /// the rows come in before it got there. "" for the clock.
    @MainActor public static var goFile: String { active ? (VisorHost.settings?.get(key: "fixture.go") ?? "") : "" }
    /// "landscape" when the app holds itself on its side for its pictures
    /// (`-visor.fixture.orientation landscape`: the iPhone's proof, as a
    /// simulator can't be turned by a command); "" for the device's way.
    @MainActor public static var orientation: String { active ? (VisorHost.settings?.get(key: "fixture.orientation") ?? "") : "" }

    /// The draft a session opens with: "/" in the chat on the commands
    /// screen, so its slash commands are offered with nothing typed;
    /// otherwise none (the fixture keeps no drafts).
    @MainActor public static func draft(session: String) -> String {
        screen == "commands" && session == chatSession ? "/" : ""
    }
    /// "dark" or "light" for pictures in one look whatever the device's
    /// (`-visor.fixture.appearance dark`); "" for the device's.
    @MainActor public static var appearance: String { active ? (VisorHost.settings?.get(key: "fixture.appearance") ?? "") : "" }

    public static let serverID = "fixture"
    /// The session a screen that shows one opens.
    public static let chatSession = "fixture-chat"
    /// The session the `goal` screen opens: working toward a goal and
    /// looping, with nothing waiting for approval, so the composer shows
    /// both pills.
    public static let goalSession = "fixture-docs"
    /// The words the search screen searches for.
    public static let searchQuery = "sync"
    /// The page the sign-in-code screen's session waits on a sign-in at
    /// (`/login`): its code is what the user sends next.
    public static let signInPage = "https://claude.ai/oauth/authorize?code=true&state=fixture"

    static let record = AgentServerRecord(id: serverID, name: "Snapshot Mac", address: "snapshot.local", everConnected: true,
                                          provider: FixtureAgentServerProvider.name)

    /// A small picture, the same bytes every run: four coloured blocks.
    static let picture = "iVBORw0KGgoAAAANSUhEUgAAAGAAAABACAIAAABqVuVZAAAAfklEQVR42u3QAQkAIAwAsIcyi2gVe5jJBta5NS4MlmAx+i2lnVlKCBIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIECRL0cVDuWmJlLYIECRIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIECRIkSJAgQYIE/Rv0AH3IYA5oDZ+mAAAAAElFTkSuQmCC"
    static let picturePath = "/Users/visor/Pictures/layout.png"
    static let moviePath = "/Users/visor/Movies/banner.mov"
    static let now: Double = 1_790_000_000
    /// The folder a session restored in the fixture runs in.
    static let restoredFolder = "/Users/visor/Developer/notes"
    /// The backups store: a session imported from a session archive, and a
    /// backup holding a session that is here still.
    static let backups: [SessionBackup] = [
        SessionBackup(path: "/Users/visor/Library/Application Support/Visor/backups/20261120-091500-import", created: now - 1800, from: "Mini",
                      sessions: [SessionBackupItem(id: "fixture-imported", title: "Field notes", outcome: "Imported.", kept: true)],
                      size: 2_400_000, imported: true),
        SessionBackup(path: "/Users/visor/Library/Application Support/Visor/backups/20261119-080000", created: now - 86_400, from: "Snapshot Mac",
                      sessions: [SessionBackupItem(id: chatSession, title: "Offline sync", outcome: "Backed up.", kept: true)], size: 9_800_000),
    ]
    /// An exported session's bytes, as the fixture's computer gives them.
    static let archive = Data("A session archive in the fixture.".utf8)

    @MainActor static var sessions: [SessionInfo] {
        func session(_ id: String, _ agent: AgentKind, _ cwd: String, _ title: String, model: String, preview: String,
                     busy: Bool = false, age: Double) -> SessionInfo {
            var info = SessionInfo(id: id, agent: agent, cwd: cwd, title: title, busy: busy, model: model, created: now - age - 3600)
            info.preview = preview
            info.updated = now - age
            // What ran is what was chosen: no fallback shown.
            info.reportedModel = nil
            info.contextUsed = 48_000
            info.contextLimit = 200_000
            // On its computer, as a 0.64 server says.
            info.placement = .host
            return info
        }
        var chat = session(chatSession, .claude, "/Users/visor/Developer/weather", "Offline sync",
                           model: "opus", preview: "Rows now sync in the background; waiting for your approval to run the tests.", age: 60)
        chat.goal = "Rows written offline are all on the server after reconnecting"
        // On the turn screens, the chat's turn as the list has it.
        if screen == "turn" || stillTurn != nil {
            let turn = stillTurn ?? turnSteps[0]
            chat.busy = turn.waits.first?.kind != .background
            chat.turn = turn
            if !chat.busy { chat.background = [StatusItem(id: "b1c43c1za", kind: .monitor, label: "CI checks on PR #92", running: true)] }
        }
        // Past what 32 bits hold, as a long session's count is: the web's
        // `Int` is 32 bits, and a client there must take it.
        chat.usage = SessionUsage(input: 3_302_964_500, cached: 3_100_000_000, output: 36_400, cost: 6.42)
        var docs = session("fixture-docs", .claude, "/Users/visor/Developer/handbook", "Release notes",
                           model: "sonnet", preview: "Drafted the notes for 2.4 with the three fixes.", age: 7200)
        docs.goal = "The release notes cover every change since 2.3"
        docs.loopCron = "*/30 * * * *"
        var widget = session("fixture-busy", .codex, "/Users/visor/Developer/weather", "Widget layout",
                             model: "gpt-5.5", preview: "Laying out the medium widget.", busy: true, age: 300)
        var sessions = [
            chat,
            widget,
            docs,
            session("fixture-api", .codex, "/Users/visor/Developer/api", "Rate limits",
                    model: "gpt-5.5", preview: "The limiter now allows bursts of 20 per minute.", age: 86_400),
        ]
        // On the `machines` screen, where each runs: the widget's agent in a
        // container (the server's own), the release notes' in the Mac's
        // Sessions container; the rest on the Mac.
        if screen == "machines" {
            widget.inContainer = true
            docs.placement = .container
            sessions = sessions.map { $0.id == docs.id ? docs : $0 }
            sessions = sessions.map { $0.id == widget.id ? widget : $0 }.map { session in
                var session = session
                session.system = session.inContainer == true ? "linux" : "macos"
                return session
            }
        }
        // On the `super-compact-done` screen, the chat carried on already.
        if screen == "super-compact-done" { sessions = continued(sessions) }
        return sessions
    }

    /// The session the chat is carried on as by a Super Compact's cut-over.
    public static let continuedSession = "fixture-continued"

    /// The sessions once the chat has been carried on: it archived and
    /// naming the session that carries it on, which names it in turn.
    static func continued(_ sessions: [SessionInfo]) -> [SessionInfo] {
        guard !sessions.contains(where: { $0.id == continuedSession }) else { return sessions }
        var next = SessionInfo(id: continuedSession, agent: .claude, cwd: "/Users/visor/Library/Application Support/Visor/Sessions/Claude/" + continuedSession,
                               title: "Offline sync (continued)", busy: false, model: "opus", created: now - 30)
        next.preview = "I've read HANDOFF.md in full and will carry on from it."
        next.updated = now - 20
        next.continuedFrom = chatSession
        return sessions.map { info in
            guard info.id == chatSession else { return info }
            var info = info
            info.archived = true
            info.continuedAs = continuedSession
            return info
        } + [next]
    }

    /// Super Compact's job in the fixture: running (the map at chunk 12 of
    /// 40), done and waiting for its review (one warning), or cut over.
    static func superCompact(_ phase: SuperCompactStatus.Phase, chunk: Int = 12, continued: Bool = false) -> SuperCompactStatus {
        SuperCompactStatus(id: "fixture-job", session: chatSession, title: "Offline sync", phase: phase, chunk: phase == .map ? chunk : 40,
                           chunks: 40, mergeStep: phase == .map ? 0 : 6, mergeSteps: 6,
                           warnings: phase == .done ? ["1 of the ledger's 9 rules and decisions isn't in HANDOFF.md: “Keep the order rows were written in”"] : [],
                           handoff: phase == .done ? "/Users/visor/Library/Application Support/Visor/super-compact/fixture-chat/fixture-job/HANDOFF.md" : nil,
                           continuedAs: continued ? continuedSession : nil, started: now - 3600, updated: now - 60,
                           finished: phase == .done ? now - 60 : nil)
    }

    /// The thread of the session the chat is carried on as.
    static let continuedTranscript: [TranscriptEntry] = [
        TranscriptEntry(id: "c1", role: .user, text: "You're continuing session \"Offline sync\" (fixture-chat). Read HANDOFF.md in this folder in full, "
                            + "in parts if it's long, before anything else, and treat its rules and decisions as the person's own."),
        TranscriptEntry(id: "c2", role: .assistant, text: "I've read HANDOFF.md in full and will carry on from it."),
    ]

    /// The fixture's HANDOFF.md.
    static let handoff = """
    # Handoff: Offline sync

    ## Who's who
    - **Offline sync** (fixture-chat): the weather app's sync, on Snapshot Mac.

    ## Rules and decisions
    - 2026-11-18: rows are written to the local store first, and marked *pending* until the server confirms them.
    - 2026-11-19: "Run the sync tests before every push."

    ## Current state
    - The retry queue is in; the offline banner matches the person's layout.

    ## Open work
    1. Run `swift test --filter SyncTests` (waiting on the person's approval).
    2. Release notes for 2.4.

    ## Timeline
    - **2026-11-18:** found rows dropped while offline; wrote them locally first.
    - **2026-11-19:** the retry queue and the banner.
    """

    static var catalogs: [AgentCatalog] {
        [AgentCatalog(agent: .claude, models: [
            AgentModel(id: "opus", title: "Opus 5.5", subtitle: "Most capable", efforts: ["low", "medium", "high"], defaultEffort: "high"),
            AgentModel(id: "sonnet", title: "Sonnet 5", subtitle: "Fast and capable", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
            AgentModel(id: "haiku", title: "Haiku 4.5", subtitle: "Fastest", efforts: []),
         ], defaultModel: "opus", account: claudeAccount),
         AgentCatalog(agent: .codex, models: [
            AgentModel(id: "gpt-5.5", title: "GPT-5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
         ], defaultModel: "gpt-5.5")]
    }

    /// A subscription's windows, as of two minutes ago. Its times are
    /// the clock's, not the fixture's: the inspector says how long until
    /// each resets, and a screenshot taken within half a minute reads the
    /// same.
    static var claudeAccount: AgentAccount {
        let now = Date().timeIntervalSince1970
        return AgentAccount(plan: "Subscription", subscription: true, limits: [
            UsageLimit(name: "5-hour", used: 0.22, resets: now + 2 * 3600 + 10 * 60 + 30),
            UsageLimit(name: "Weekly", used: 0.82, resets: now + 3 * 86_400 + 4 * 3600 + 30),
        ], updated: now - 150)
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
        - **keep the order rows were written in**, so a row edited twice while offline reaches the server as its last edit, not its first

        ```swift
        func save(_ row: Row) throws {
            try store.insert(row, state: .pending)
            queue.enqueue(row.id)
        }
        ```

        See [the sync notes](https://example.com/sync) for the retry rules.
        """),
        TranscriptEntry(id: "f5", role: .user, text: "Here's the layout I want for the offline banner.", images: [picturePath, moviePath],
                        imageSizes: [ImageSize(width: 96, height: 64)]),
        TranscriptEntry(id: "f6", role: .user, text: "/goal Rows written offline are all on the server after reconnecting"),
        TranscriptEntry(id: "f7", role: .tool, text: "Rows written offline are all on the server after reconnecting", toolName: "goal"),
        TranscriptEntry(id: "f8", role: .assistant, text: "", activities: ["Edit: Sources/Sync/RowStore.swift", "Edit: Sources/Sync/SyncQueue.swift", "Bash: swift build"]),
        TranscriptEntry(id: "f9", role: .assistant, text: "Rows now sync in the background, and the banner matches your layout. I'd like to run the tests next."),
    ]

    /// The turn screen's turn, a state every `turnStep` from the chat's
    /// opening (thinking, as it opens): responding, running the tests,
    /// two subagents, responding again; then the turn's end, and its
    /// reply's row (`turnReply`) with the sync `turnStep` after.
    static let turnSteps: [TurnState] = [
        TurnState(.thinking),
        TurnState(.responding),
        TurnState(.waiting, waits: [TurnWait(kind: .tool, id: "toolu_tests", label: "Bash: swift test --filter SyncTests", work: .shell)]),
        TurnState(.waiting, waits: [TurnWait(kind: .subagent, id: "toolu_a", label: "Review the sync queue", work: .subagent),
                                    TurnWait(kind: .subagent, id: "toolu_b", label: "Check the banner's copy", work: .subagent)]),
        TurnState(.responding),
    ]
    static let turnStep: UInt64 = 1_500_000_000
    static let turnReply = TranscriptEntry(id: "msg_fixture_reply", role: .assistant,
                                           text: "All 42 sync tests pass, offline rows included, and the banner shows how many are still waiting.")

    /// The state a turn-‹state› screen holds the chat in; nil on any other.
    @MainActor static var stillTurn: TurnState? {
        switch screen {
        case "turn-tool": turnSteps[2]
        case "turn-subagents": turnSteps[3]
        case "turn-background":
            TurnState(.waiting, waits: [TurnWait(kind: .background, id: "b1c43c1za", label: "CI checks on PR #92", work: .monitor)])
        default: nil
        }
    }

    /// The question the question screen's chat waits on (AskUserQuestion).
    static let question = ApprovalRequest(
        id: "fixture-question", tool: "AskUserQuestion", summary: "Which way should rows written offline go to the server?",
        questions: [AgentQuestion(question: "Which way should rows written offline go to the server?", header: "Sync",
                                  options: [AgentQuestion.Option(label: "On reconnect", description: "Everything kept goes as soon as the network is back."),
                                            AgentQuestion.Option(label: "In the background", description: "A few at a time while the app is in use.")])])
}

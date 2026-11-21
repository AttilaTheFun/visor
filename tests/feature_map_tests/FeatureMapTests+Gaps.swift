// What FEATURE_MAP.md has that these tests can't take yet, each a test that
// doesn't run, with why: a step that happens by itself (the agent asking),
// or one the fixture's computer doesn't have or answer (a second computer
// to migrate to, an archived session, a fork). Each says how it could be
// taken once that changes.

import Testing

extension FeatureMapTests {
    @Suite("Not driven yet")
    struct Gaps {
        @Test("Sessions → Migrate sheet: longpress session-‹id›, “Migrate…”, ‹another computer›",
              .disabled("Migrate… opens (Sessions' movesIntoTheContainerAndBack takes it, for the fixture's Sessions container), but another computer is offered only when a second connected computer migrates: the fixture has one, whose computer doesn't migrate"))
        func migrate() {}

        @Test("Sessions → Archived Sessions: tap archived-‹name›",
              .disabled("the fixture has no archived session, and its computer doesn't answer Session details' Archive or a row's swipe “Archive” (the row stays): no archived-‹name› row to tap"))
        func archived() {}

        @Test("Archived Sessions → Sessions: swipe “Unarchive”",
              .disabled("the driver's swipe takes a row's swipe actions now (swipe <row> left, “Unarchive”), but Archived Sessions isn't reached (above)"))
        func unarchive() {}

        @Test("Model sheet → All Models: tap all-models",
              .disabled("All Models is offered for a long catalog (OpenRouter's, with unlisted models); the fixture's catalogs list every model, so the sheet has no all-models"))
        func allModels() {}

        @Test("Session chat ⇢ Approval controls: the agent asks for a tool",
              .disabled("an event, not a command: the chat fixture opens with a Bash approval waiting (FixtureScreens' chat → approval)"))
        func approvalArrives() {}

        @Test("Session chat ⇢ Question sheet: the agent asks a question",
              .disabled("an event, not a command: the question fixture opens with the question asked (FixtureScreens' question)"))
        func questionArrives() {}

        @Test("Session chat → Fork, Branch: type /fork or /branch, tap “Send”; back",
              .disabled("the fixture's computer doesn't fork: the page that opens is an empty “Session”, not “Fork of …”, and back goes to Sessions rather than the chat (Chat's sideQuestions takes /btw)"))
        func forkAndBranch() {}

        @Test("Session chat: a row that comes in is scrolled to at the thread's end, and not while read further up",
              .disabled("headless, the transcript's List doesn't move for ScrollViewReader's scrollTo and reports no scroll geometry "
                        + "(measured 21 Nov 2026 with the driver's layout on `turn`: the thread opens at its top, and the reply's "
                        + "row lands below the window), and a drag on it is refused (“nothing on the screen takes a swipe”); "
                        + "takeable once Isomer's portable List scrolls and the layout reports where"))
        func followsTheEnd() {}

        @Test("Session chat → Subagent: tap a subagent's row",
              .disabled("the fixture's transcript has no subagent"))
        func subagent() {}

        @Test("Restore a session → Import: tap import-archive",
              .disabled("Import… opens the system's file picker (an open panel, Files, a file input), which the driver can't answer: it has no command for a picker's file (the server's import is SessionArchiveTests')"))
        func importArchive() {}

        @Test("Export a session → saved: tap export-save",
              .disabled("Save… opens the system's save panel (a file exporter), which the driver can't answer: it has no command for where to save (the export itself is SessionArchiveTests')"))
        func saveExport() {}

        @Test("File › Export… and File › Import… (the Mac's menu bar)",
              .disabled("Isomer's hosts draw no menu bar, and the driver has no command for one: the items open the same Export a session sheet and Restore a session that the session's menu and New Session's Restore open, which are taken"))
        func macFileMenu() {}
    }
}

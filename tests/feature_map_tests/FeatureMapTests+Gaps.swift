// What FEATURE_MAP.md has that these tests can't take yet, each a test that
// doesn't run, with why: a step the driver protocol has no command for (a
// context menu, a swipe action), one that happens by itself (the agent
// asking), or one the fixture's computer doesn't answer. Each says how it
// could be taken once that changes.

import Testing

extension FeatureMapTests {
    @Suite("Not driven yet")
    struct Gaps {
        @Test("Sessions ⇢ Project settings: context menu “Project Settings”",
              .disabled("a context menu needs a long press, which the driver protocol (isomer's headless.proto) has no command for"))
        func projectSettings() {}

        @Test("Sessions ⇢ Migrate sheet: context menu “Migrate…”",
              .disabled("a context menu needs a long press, which the driver protocol has no command for; and the fixture has one computer to migrate to"))
        func migrate() {}

        @Test("Sessions → Archived Sessions: tap archived-‹name›",
              .disabled("the fixture has no archived session, and its computer doesn't answer Session details' Archive (the row stays): no archived-‹name› row to tap"))
        func archived() {}

        @Test("Archived Sessions ⇢ Sessions: swipe “Unarchive”",
              .disabled("a List row's swipe action: the driver's swipe drags a view, it doesn't open a row's swipe actions; and Archived Sessions isn't reached (above)"))
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

        @Test("Session chat → Subagent: tap a subagent's row",
              .disabled("the fixture's transcript has no subagent"))
        func subagent() {}
    }
}

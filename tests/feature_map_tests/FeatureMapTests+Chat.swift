// From a session's chat, on a phone's width: its details, its model, the
// approval and question waiting in it, its tool calls, an attachment, and
// the pages a slash command opens.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Session chat")
    struct Chat {
        /// The composer's field, by its placeholder: it has no identifier
        /// (AgentUI's DraftField).
        static let composer = "Message Claude Code"

        /// The fixture's `screen`, once its chat is up.
        private func chat(_ screen: String = "chat") throws -> HeadlessApp {
            let app = try VisorLaunch.fixture(screen)
            try app.screen { FeatureMapNode.chat.isShown(on: $0) }
            return app
        }

        @Test("Session chat → Session details: tap session-title, and back by details-done")
        func details() throws {
            let app = try chat()
            defer { app.quit() }
            let details = try app.tap("session-title")
            FeatureMapNode.details.expectShown(on: details)
            // Its folder is here, not in its row in Sessions.
            #expect(details.shows("/Users/visor/Developer/weather") || details.elements.contains { ($0.value ?? "").contains("/Users/visor/Developer/weather") },
                    "the folder: \(details.summary)")
            FeatureMapNode.chat.expectShown(on: try app.tap("details-done"))
        }

        /// The session's notifications switch: on unless switched off, and
        /// kept where it was put (the fixture's computer keeps it, as a
        /// computer keeps it for every device), on Session details still.
        @Test("Session details: set details-notifications off, and on again")
        func notifications() throws {
            let app = try VisorLaunch.fixture("inspector")
            defer { app.quit() }
            let details = try app.screen { FeatureMapNode.details.isShown(on: $0) }
            FeatureMapNode.details.expectShown(on: details)
            #expect(details.element("details-notifications")?.value == "1", "on by default: \(details.summary)")
            try app.set("details-notifications", "0")
            let off = try app.screen { $0.element("details-notifications")?.value == "0" }
            #expect(off.element("details-notifications")?.value == "0", "switched off: \(off.summary)")
            FeatureMapNode.details.expectShown(on: off)
            try app.set("details-notifications", "1")
            let on = try app.screen { $0.element("details-notifications")?.value == "1" }
            #expect(on.element("details-notifications")?.value == "1", "on again: \(on.summary)")
        }

        @Test("Session chat → Model sheet: tap model")
        func model() throws {
            // The goal's session: nothing waits for approval, so the
            // composer's row has the model's pill (the chat's has the
            // approval in its place).
            let app = try chat("goal")
            defer { app.quit() }
            let screen = try app.tap("model")
            FeatureMapNode.model.expectShown(on: screen)
            FeatureMapNode.chat.expectShown(on: try app.dismiss())
        }

        @Test("Approval controls → Session chat: tap allow or deny", arguments: ["allow", "deny"])
        func approval(id: String) throws {
            let app = try chat()
            defer { app.quit() }
            FeatureMapNode.approval.expectShown(on: try app.screen())
            // The fixture's computer answers no approval: the request stays,
            // and the chat is where the tap leaves it.
            FeatureMapNode.chat.expectShown(on: try app.tap(id))
        }

        @Test("Approval controls → Question sheet: tap answer")
        func answer() throws {
            // The question screen's chat: its sheet put away, the question
            // waits in the composer's place, answered from there.
            let app = try VisorLaunch.fixture("question")
            defer { app.quit() }
            try app.screen { FeatureMapNode.question.isShown(on: $0) }
            let chat = try app.dismiss()
            FeatureMapNode.approval.expectShown(on: chat)
            FeatureMapNode.question.expectShown(on: try app.tap("answer"))
        }

        @Test("Question sheet → Session chat: tap approval-‹option›, tap question-send")
        func question() throws {
            let app = try VisorLaunch.fixture("question")
            defer { app.quit() }
            try app.screen { FeatureMapNode.question.isShown(on: $0) }
            let chosen = try app.tap("approval-On reconnect")
            #expect(chosen.has(id: "question-send") || chosen.has(label: "Send"), "\(chosen.summary)")
            FeatureMapNode.chat.expectShown(on: try app.tap("question-send"))
        }

        @Test("Session chat → Tool calls: tap “Made N tool calls”")
        func toolCalls() throws {
            let app = try chat()
            defer { app.quit() }
            FeatureMapNode.toolCalls.expectShown(on: try app.tap("Made 2 tool calls"))
            FeatureMapNode.chat.expectShown(on: try app.dismiss())
        }

        @Test("Session chat → Attachment preview: tap attachment-‹file›")
        func attachment() throws {
            let app = try chat()
            defer { app.quit() }
            FeatureMapNode.preview.expectShown(on: try app.tap("attachment-layout.png"))
            try app.dismiss()
            // (Quick Look's preview, on the iPhone, goes a moment after.)
            FeatureMapNode.chat.expectShown(on: try app.screen { FeatureMapNode.chat.isShown(on: $0) })
        }

        /// The turn's line under the thread (the `turn` fixture,
        /// VisorFixture's `turnSteps`): one state after another as the
        /// server tells them, never any of the reply's words, then the
        /// reply's row once it syncs, once, and the line gone. (Not among
        /// FixtureScreens': while the turn runs the composer offers Stop,
        /// not Send, so the chat is told by its end.)
        /// An approval or a question the chat waits on: in Sessions, its
        /// row's own mark, a raised hand or a question (`activity-‹id›`),
        /// where any other wait is a clock.
        @Test("Session chat → Sessions: back; the row marks what waits on the person", arguments: [
            ("chat", "Waiting for your approval"),
            ("question", "Asking you a question"),
        ])
        func waitsOnThePerson(screen: String, mark: String) throws {
            let app = try VisorLaunch.fixture(screen)
            defer { app.quit() }
            if screen == "question" {
                try app.screen { FeatureMapNode.question.isShown(on: $0) }
                try app.dismiss()
            }
            try app.screen { FeatureMapNode.chat.isShown(on: $0) }
            _ = try app.back()
            let listed = try app.screen { $0.row("Offline sync", marked: "activity-fixture-chat", mark) }
            #expect(listed.row("Offline sync", marked: "activity-fixture-chat", mark), "the list's mark: \(listed.summary)")
        }

        @Test("Session chat: the turn's line through its states, then the reply's row")
        func turnStates() throws {
            let reply = "All 42 sync tests pass, offline rows included, and the banner shows how many are still waiting."
            let app = try VisorLaunch.fixture("turn")
            defer { app.quit() }
            for words in ["Thinking…", "Responding…", "Running Bash: swift test --filter SyncTests", "Waiting for 2 subagents"] {
                let screen = try app.screen(within: 15) { $0.texts.contains(words) }
                #expect(screen.texts.contains(words), "the line says \(words): \(screen.summary)")
                #expect(!screen.texts.contains { $0.hasPrefix("All 42") }, "none of the reply before its row: \(screen.summary)")
            }
            let landed = try app.screen(within: 20) { $0.texts.contains(reply) }
            #expect(landed.texts.filter { $0 == reply }.count == 1, "the reply's row, once: \(landed.summary)")
            #expect(!landed.texts.contains("Responding…") && !landed.texts.contains("Thinking…"), "the line gone: \(landed.summary)")
            FeatureMapNode.chat.expectShown(on: landed)
            // (Whether the thread went down to it can't be told here:
            // Gaps' `followsTheEnd`.)
        }

        /// A turn held in one state (the turn-‹state› fixtures): its words
        /// under the thread; on the iPhone's Sessions page only the mark
        /// at the end of the session's first line (`activity-‹id›`): a
        /// spinner while the agent runs a tool call of its own, a clock
        /// while it waits on anything else (subagents, a monitor), and
        /// its goal's flag (`goal-‹id›`). The words stay the chat's.
        @Test("Session chat: a waiting turn's line in the chat, its mark in the list", arguments: [
            ("turn-tool", "Running Bash: swift test --filter SyncTests", "Working"),
            ("turn-subagents", "Waiting for 2 subagents", "Waiting"),
            ("turn-background", "Waiting on CI checks on PR #92", "Waiting"),
        ])
        func turnWaiting(screen: String, words: String, mark: String) throws {
            let app = try VisorLaunch.fixture(screen)
            defer { app.quit() }
            let chat = try app.screen(within: 10) { $0.texts.contains(words) }
            #expect(chat.texts.contains(words), "the chat's line: \(chat.summary)")
            #expect(chat.has(id: "session-title"), "the chat: \(chat.summary)")
            _ = try app.back()
            let listed = try app.screen { $0.row("Offline sync", marked: "activity-fixture-chat", mark) }
            #expect(listed.row("Offline sync", marked: "activity-fixture-chat", mark), "the list's mark: \(listed.summary)")
            #expect(listed.row("Offline sync", marked: "goal-fixture-chat", "Goal: Rows written offline are all on the server after reconnecting"),
                    "the goal's flag: \(listed.summary)")
            #expect(!listed.has(id: "waiting-fixture-chat"), "no line of the turn's under its row: \(listed.summary)")
        }

        @Test("Session chat → Side Questions: type /btw, tap “Send”; back")
        func sideQuestions() throws {
            let app = try chat()
            defer { app.quit() }
            try app.type(Self.composer, "/btw Which tests cover the sync?")
            FeatureMapNode.subPage.expectShown(on: try app.tap("Send"))
            let back = try app.back()
            FeatureMapNode.chat.expectShown(on: back)
            #expect(back.titled("Offline sync"), "\(back.summary)")
        }
    }
}

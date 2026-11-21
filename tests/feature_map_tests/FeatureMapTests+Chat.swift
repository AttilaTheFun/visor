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
            FeatureMapNode.details.expectShown(on: try app.tap("session-title"))
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
        /// reply's row once it syncs, once, scrolled to (the thread was at
        /// its end), and the line gone. (Not among FixtureScreens': while
        /// the turn runs the composer offers Stop, not Send, so the chat is
        /// told by its end.)
        @Test("Session chat: the turn's line through its states, then the reply's row, scrolled to")
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
            // At the thread's end when it came: the thread went down to it.
            let layout = try app.layout()
            let frame = layout.frame(of: reply)
            #expect(frame.map { $0.minY >= 0 && $0.maxY <= layout.height } == true,
                    "the reply's row in view: \(String(describing: frame)) in \(layout.height)")
        }

        /// Read further up when the reply comes: the thread stays where it
        /// is, and the pill says a row came in below.
        @Test("Session chat: a row that comes while read further up leaves the thread still, with new-rows-pill")
        func turnRowWhileScrolledUp() throws {
            let reply = "All 42 sync tests pass, offline rows included, and the banner shows how many are still waiting."
            let app = try VisorLaunch.fixture("turn")
            defer { app.quit() }
            try app.screen(within: 10) { $0.texts.contains("Thinking…") }
            for _ in 0..<4 { _ = try app.swipe("", "down") }
            // A row of the thread in view, read: where it is.
            let read = try app.layout()
            let rows = ["The weather app loses rows when the phone goes offline. Can you make the sync survive that?",
                        "I'll look at how rows are written first.", "No matches outside RowStore."]
            let kept = rows.first { read.frame(of: $0).map { $0.minY >= 0 && $0.maxY <= read.height } == true }
            #expect(kept != nil, "up the thread: \(read.items.map(\.label).prefix(20))")
            let landed = try app.screen(within: 30) { $0.has(id: "new-rows-pill") }
            #expect(landed.has(id: "new-rows-pill"), "the pill: \(landed.summary)")
            let layout = try app.layout()
            if let kept { #expect(layout.frame(of: kept) == read.frame(of: kept), "what was read stayed where it was") }
            if let row = layout.frame(of: reply) { #expect(row.minY >= layout.height, "the reply below, out of view: \(row)") }
        }

        /// A turn held in one state (the turn-‹state› fixtures): its words
        /// under the thread, and on the iPhone's Sessions page under the
        /// session's row (`waiting-‹id›`).
        @Test("Session chat: a waiting turn's line, in the chat and in the list", arguments: [
            ("turn-tool", "Running Bash: swift test --filter SyncTests"),
            ("turn-subagents", "Waiting for 2 subagents"),
            ("turn-background", "Waiting on CI checks on PR #92"),
        ])
        func turnWaiting(screen: String, words: String) throws {
            let app = try VisorLaunch.fixture(screen)
            defer { app.quit() }
            let chat = try app.screen(within: 10) { $0.texts.contains(words) }
            #expect(chat.texts.contains(words), "the chat's line: \(chat.summary)")
            #expect(chat.has(id: "session-title"), "the chat: \(chat.summary)")
            let list = try app.back()
            let listed = try app.screen { $0.has(id: "waiting-fixture-chat") }
            #expect(listed.element("waiting-fixture-chat")?.label == words || listed.texts.contains(words),
                    "the list's line: \(list.summary)")
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

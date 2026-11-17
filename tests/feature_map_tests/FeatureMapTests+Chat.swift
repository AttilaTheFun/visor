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

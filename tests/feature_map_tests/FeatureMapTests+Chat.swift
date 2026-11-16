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

        /// The composer as the driver names it: by its placeholder, or on
        /// the iPhone, where Isomer's Apple driver gives it no label, the
        /// chat's one text field by its name.
        private func composer(_ app: HeadlessApp) throws -> String {
            let screen = try app.screen()
            if screen.element(Self.composer) != nil { return Self.composer }
            return screen.elements.first { $0.role == "textField" }?.name ?? Self.composer
        }

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
            FeatureMapNode.details.expectShown(on: try app.tap(id: "session-title", else: "Session details"))
            FeatureMapNode.chat.expectShown(on: try app.tap(id: "details-done", else: "Done"))
        }

        @Test("Session chat → Model sheet: tap model")
        func model() throws {
            // The goal's session: nothing waits for approval, so the
            // composer's row has the model's pill (the chat's has the
            // approval in its place).
            let app = try chat("goal")
            defer { app.quit() }
            let screen = try app.tap(id: "model", else: "Sonnet 5", .wrappedControl)
            FeatureMapNode.model.expectShown(on: screen)
            FeatureMapNode.chat.expectShown(on: try app.putAway())
        }

        @Test("Approval controls → Session chat: tap allow or deny", arguments: [("allow", "Allow"), ("deny", "Deny")])
        func approval(id: String, label: String) throws {
            let app = try chat()
            defer { app.quit() }
            FeatureMapNode.approval.expectShown(on: try app.screen())
            // The fixture's computer answers no approval: the request stays,
            // and the chat is where the tap leaves it.
            FeatureMapNode.chat.expectShown(on: try app.tap(id: id, else: label, .wrappedControl))
        }

        @Test("Approval controls → Question sheet: tap answer")
        func answer() throws {
            // The question screen's chat: its sheet put away, the question
            // waits in the composer's place, answered from there.
            let app = try VisorLaunch.fixture("question")
            defer { app.quit() }
            try app.screen { FeatureMapNode.question.isShown(on: $0) }
            let chat = try app.putAway()
            FeatureMapNode.approval.expectShown(on: chat)
            FeatureMapNode.question.expectShown(on: try app.tap(id: "answer", else: "Answer", .wrappedControl))
        }

        @Test("Question sheet → Session chat: tap approval-‹option›, tap question-send")
        func question() throws {
            let app = try VisorLaunch.fixture("question")
            defer { app.quit() }
            try app.screen { FeatureMapNode.question.isShown(on: $0) }
            let chosen = try app.tap(id: "approval-On reconnect", else: "On reconnect")
            #expect(chosen.has(id: "question-send") || chosen.has(label: "Send"), "\(chosen.summary)")
            FeatureMapNode.chat.expectShown(on: try app.tap(id: "question-send", else: "Send"))
        }

        @Test("Session chat → Tool calls: tap “Made N tool calls”")
        func toolCalls() throws {
            let app = try chat()
            defer { app.quit() }
            FeatureMapNode.toolCalls.expectShown(on: try app.tap("Made 2 tool calls"))
            FeatureMapNode.chat.expectShown(on: try app.putAway())
        }

        @Test("Session chat → Attachment preview: tap attachment-‹file›")
        func attachment() throws {
            let app = try chat()
            defer { app.quit() }
            FeatureMapNode.preview.expectShown(on: try app.tap(id: "attachment-layout.png", else: "Open the attachment"))
            try app.putAway()
            // (Quick Look's preview, on the iPhone, goes a moment after.)
            FeatureMapNode.chat.expectShown(on: try app.screen { FeatureMapNode.chat.isShown(on: $0) })
        }

        @Test("Session chat → Side Questions: type /btw, tap “Send”; back")
        func sideQuestions() throws {
            let app = try chat()
            defer { app.quit() }
            try app.type(try composer(app), "/btw Which tests cover the sync?")
            FeatureMapNode.subPage.expectShown(on: try app.tap("Send"))
            let back = try app.back()
            FeatureMapNode.chat.expectShown(on: back)
            #expect(back.titled("Offline sync"), "\(back.summary)")
        }
    }
}

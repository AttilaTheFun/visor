// The same graph at a regular width (an iPad, the Mac, a wide window): the
// list and the chat side by side, Settings and Session details a pane
// beside them, "New session" in the toolbar. Headless alone for now: a
// headful device's width is its own.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Regular width", .enabled(if: VisorLaunch.headless, "a headful device's width is its own"))
    struct RegularWidth {
        @Test("Sessions → New Session: tap new-session (the toolbar's)")
        func newSession() throws {
            let app = try VisorLaunch.fixture("sessions", width: .regular)
            defer { app.quit() }
            try app.screen { $0.has(id: "new-session") }
            FeatureMapNode.newSession.expectShown(on: try app.tap("new-session"))
        }

        @Test("Session chat ⇄ Session details: tap session-title, and again")
        func detailsPane() throws {
            let app = try VisorLaunch.fixture("chat", width: .regular)
            defer { app.quit() }
            try app.screen { FeatureMapNode.chat.isShown(on: $0) }
            let open = try app.tap("session-title")
            FeatureMapNode.details.expectShown(on: open)
            // Beside the chat, not over it.
            FeatureMapNode.chat.expectShown(on: open)
            #expect(open.presented.isEmpty, "\(open.summary)")
            let closed = try app.tap("session-title")
            #expect(!FeatureMapNode.details.isShown(on: closed), "\(closed.summary)")
        }

        @Test("Settings pane: a computer's page and back by settings-back; closed by settings")
        func settingsPane() throws {
            let app = try VisorLaunch.fixture("sessions", width: .regular)
            defer { app.quit() }
            try app.screen { $0.has(id: "settings") && $0.has(id: "new-session") }
            FeatureMapNode.settings.expectShown(on: try app.tap("settings"))
            FeatureMapNode.computer.expectShown(on: try app.tap("settings-computer-Snapshot Mac"))
            FeatureMapNode.settings.expectShown(on: try app.tap("settings-back"))
            let closed = try app.tap("settings")
            #expect(!FeatureMapNode.settings.isShown(on: closed), "\(closed.summary)")
        }
    }
}

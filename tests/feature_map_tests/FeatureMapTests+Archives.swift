// A session exported as a session archive, from its menu, and one restored
// from New Session's Restore: an imported session to choose, one still on
// the computer offered but not restorable (remove it first). The Mac's File
// › Export… and File › Import… open the same sheets.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Export and Restore")
    struct Archives {
        /// Whether `text` is on the screen: a text, or in an element's
        /// label or value (a row's button holds its texts).
        static func mentions(_ screen: HeadlessScreen, _ text: String) -> Bool {
            screen.shows(text) || screen.elements.contains { $0.label.contains(text) || ($0.value ?? "").contains(text) }
        }

        @Test("Sessions → Export a session: longpress session-‹id›, tap “Export…”")
        func exports() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            let menu = try app.longPress("session-fixture-chat")
            #expect(menu.element("Export…") != nil, "no Export… in the menu: \(menu.summary)")
            FeatureMapNode.export.expectShown(on: try app.tap("Export…"))
            // Read from the fixture's computer at once: ready to save.
            let ready = try app.screen { $0.has(id: "export-save") }
            #expect(Self.mentions(ready, "Offline sync-2026-11-20.visorsession"), "\(ready.summary)")
        }

        @Test("Export a session → Sessions: tap export-done")
        func exportDone() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            try app.longPress("session-fixture-chat")
            try app.tap("Export…")
            try app.screen { $0.has(id: "export-save") }
            FeatureMapNode.sessions.expectShown(on: try app.tap("export-done"))
        }

        @Test("New Session → Restore a session: select conversation “Restore”")
        func choosesRestore() throws {
            let app = try VisorLaunch.fixture("new-session")
            defer { app.quit() }
            try app.screen { FeatureMapNode.newSession.isShown(on: $0) }
            try app.select("conversation", "Restore")
            let screen = try app.screen { FeatureMapNode.restore.isShown(on: $0) && $0.has(id: "restore-fixture-imported") }
            FeatureMapNode.restore.expectShown(on: screen)
            // The backed-up session still here is listed, to remove first.
            #expect(screen.has(id: "restore-fixture-chat"), "\(screen.summary)")
            #expect(Self.mentions(screen, "remove it first"), "\(screen.summary)")
        }

        @Test("Restore a session → Session chat: tap restore-‹id›, tap start")
        func restores() throws {
            let app = try VisorLaunch.fixture("restore")
            defer { app.quit() }
            try app.screen { FeatureMapNode.restore.isShown(on: $0) && $0.has(id: "restore-fixture-imported") }
            try app.tap("restore-fixture-imported")
            let screen = try app.tap("start")
            let chat = try app.screen { FeatureMapNode.chat.isShown(on: $0) }
            FeatureMapNode.chat.expectShown(on: chat)
            #expect(chat.titled("Field notes") || screen.titled("Field notes"), "\(chat.summary)")
        }
    }
}

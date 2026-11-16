// New Session and its folder picker.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("New Session")
    struct NewSession {
        @Test("New Session → Choose a folder: tap project")
        func choosesAFolder() throws {
            let app = try VisorLaunch.fixture("new-session")
            defer { app.quit() }
            try app.screen { FeatureMapNode.newSession.isShown(on: $0) }
            FeatureMapNode.folder.expectShown(on: try app.tap(id: "project", else: "Choose Folder…"))
        }

        @Test("Choose a folder → New Session: tap choose-folder")
        func folderChosen() throws {
            let app = try VisorLaunch.fixture("new-session")
            defer { app.quit() }
            try app.screen { FeatureMapNode.newSession.isShown(on: $0) }
            try app.tap(id: "project", else: "Choose Folder…")
            FeatureMapNode.newSession.expectShown(on: try app.tap(id: "choose-folder", else: "Choose"))
        }

        @Test("New Session → Session chat: type first-message, tap start")
        func starts() throws {
            let app = try VisorLaunch.fixture("new-session")
            defer { app.quit() }
            let screen = try app.screen { FeatureMapNode.newSession.isShown(on: $0) }
            // The first message where the computer takes one (the fixture's
            // doesn't: no `first-message`).
            if screen.has(id: "first-message") { try app.type("first-message", "Tidy the README") }
            FeatureMapNode.chat.expectShown(on: try app.tap(id: "start", else: "Start"))
        }
    }
}

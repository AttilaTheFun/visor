// New Session and its folder picker, and where the session runs: the
// computer, or its Sessions container while that takes sessions.

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
            FeatureMapNode.folder.expectShown(on: try app.tap("project"))
        }

        @Test("Choose a folder → New Session: tap choose-folder")
        func folderChosen() throws {
            let app = try VisorLaunch.fixture("new-session")
            defer { app.quit() }
            try app.screen { FeatureMapNode.newSession.isShown(on: $0) }
            try app.tap("project")
            FeatureMapNode.newSession.expectShown(on: try app.tap("choose-folder"))
        }

        @Test("New Session → Session chat: type first-message, tap start")
        func starts() throws {
            let app = try VisorLaunch.fixture("new-session")
            defer { app.quit() }
            let screen = try app.screen { FeatureMapNode.newSession.isShown(on: $0) }
            // The first message where the computer takes one (the fixture's
            // doesn't: no `first-message`).
            if screen.has(id: "first-message") { try app.type("first-message", "Tidy the README") }
            FeatureMapNode.chat.expectShown(on: try app.tap("start"))
        }

        /// Whether `text` is on the screen: a text, or in an element's
        /// label or value.
        static func mentions(_ screen: HeadlessScreen, _ text: String) -> Bool {
            screen.shows(text) || screen.elements.contains { $0.label.contains(text) || ($0.value ?? "").contains(text) }
        }

        @Test("New Session → New Session in the container: select compose-place “‹computer›'s Container”; and back, “‹computer›”")
        func choosesTheContainer() throws {
            let app = try VisorLaunch.fixture("new-session")
            defer { app.quit() }
            // The fixture's computer has a Sessions container that takes
            // sessions: where it runs is asked once the computer says so.
            let screen = try app.screen { FeatureMapNode.newSession.isShown(on: $0) && $0.has(id: "compose-place") }
            #expect(screen.element("compose-place")?.options == ["Snapshot Mac", "Snapshot Mac's Container"], "\(screen.summary)")
            try app.select("compose-place", "Snapshot Mac's Container")
            // Claude Code alone, in a folder of its own there: no folder to
            // pick, and its model and effort chosen here.
            let chosen = try app.screen { FeatureMapNode.newInContainer.isShown(on: $0) }
            FeatureMapNode.newInContainer.expectShown(on: chosen)
            #expect(!chosen.has(id: "project") && chosen.has(id: "compose-model") && chosen.has(id: "compose-effort"), "\(chosen.summary)")
            try app.select("compose-place", "Snapshot Mac")
            let back = try app.screen { $0.has(id: "project") }
            #expect(back.has(id: "project") && !FeatureMapNode.newInContainer.isShown(on: back), "\(back.summary)")
        }

        @Test("New Session in the container → Session chat: tap start; its row in Sessions marked")
        func startsInTheContainer() throws {
            let app = try VisorLaunch.fixture("new-session")
            defer { app.quit() }
            try app.screen { FeatureMapNode.newSession.isShown(on: $0) && $0.has(id: "compose-place") }
            try app.select("compose-place", "Snapshot Mac's Container")
            try app.screen { FeatureMapNode.newInContainer.isShown(on: $0) }
            try app.select("compose-model", "Sonnet 5")
            try app.tap("start")
            FeatureMapNode.chat.expectShown(on: try app.screen { FeatureMapNode.chat.isShown(on: $0) })
            // Its row marks it in the Sessions container (on a phone, back
            // from its chat).
            func marked(_ screen: HeadlessScreen) -> Bool { screen.element("place-fixture-container")?.label == "In the Sessions container" }
            var placed = try app.screen(within: 1) { marked($0) }
            if !marked(placed) {
                try app.back()
                placed = try app.screen { marked($0) }
            }
            FeatureMapNode.sessions.expectShown(on: placed)
            #expect(marked(placed), "\(placed.summary)")
        }

        @Test("New Session in the container → New Session in the container: tap start, refused (start-error)")
        func containerRefusalStaysOpen() throws {
            let app = try VisorLaunch.fixture("new-session-container-refused")
            defer { app.quit() }
            try app.screen { FeatureMapNode.newSession.isShown(on: $0) && $0.has(id: "compose-place") }
            try app.select("compose-place", "Snapshot Mac's Container")
            try app.screen { FeatureMapNode.newInContainer.isShown(on: $0) }
            try app.tap("start")
            // The computer's words, and the sheet still open to try again.
            let refused = try app.screen { $0.has(id: "start-error") }
            FeatureMapNode.newInContainer.expectShown(on: refused)
            #expect(Self.mentions(refused, "no egress"), "\(refused.summary)")
            #expect(refused.has(id: "compose-place") && refused.has(id: "start"), "\(refused.summary)")
        }

        @Test("New Session: no compose-place while the computer's Sessions container takes no sessions")
        func noContainerOffered() throws {
            let app = try VisorLaunch.fixture("new-session-no-container")
            defer { app.quit() }
            try app.screen { FeatureMapNode.newSession.isShown(on: $0) && $0.has(id: "project") }
            // Its container off: given time to say so, where it runs is
            // never asked, and the folder is, as on any computer.
            let screen = try app.screen(within: 2) { $0.has(id: "compose-place") }
            #expect(!screen.has(id: "compose-place") && screen.has(id: "project"), "\(screen.summary)")
        }
    }
}

// From Sessions (the computers and their sessions), on a phone's width,
// and from its search.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Sessions and search")
    struct Sessions {
        @Test("Sessions → Add Computer: tap add-computer")
        func addsAComputer() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            FeatureMapNode.addComputer.expectShown(on: try app.tap(id: "add-computer", else: "Add Computer…"))
        }

        @Test("Sessions → Search results: type “Search sessions” ‹text›")
        func searches() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            try app.type("Search sessions", "sync")
            // The messages found come from the computer a moment later.
            FeatureMapNode.search.expectShown(on: try app.screen { FeatureMapNode.search.isShown(on: $0) })
        }

        @Test("Sessions → New Session: tap “New session”")
        func startsASession() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            // The bottom bar's compose, by its title (IsomerGap.bottomBarTitle).
            let target: String
            if try app.screen().element("New session") != nil {
                target = "New session"
            } else {
                withKnownIssue(Comment(rawValue: IsomerGap.bottomBarTitle.rawValue)) {
                    Issue.record("no element “New session”: found by “✎”")
                }
                target = "✎"
            }
            FeatureMapNode.newSession.expectShown(on: try app.tap(target))
        }

        @Test("Sessions → Session chat: tap session-‹id›")
        func opensAChat() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            let screen = try app.tap(id: "session-fixture-chat", else: "Offline sync", .listRow)
            FeatureMapNode.chat.expectShown(on: screen)
            #expect(screen.titled("Offline sync"), "\(screen.summary)")
        }

        @Test("Session chat → Sessions: back (a phone's stack)")
        func backFromAChat() throws {
            let app = try VisorLaunch.fixture("chat")
            defer { app.quit() }
            try app.screen { FeatureMapNode.chat.isShown(on: $0) }
            FeatureMapNode.sessions.expectShown(on: try app.back())
        }

        @Test("Sessions → Project settings: longpress session-‹id›, tap “Project Settings”")
        func projectSettings() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            let row = try app.target(id: "session-fixture-chat", else: "Offline sync", .listRow)
            let menu: HeadlessScreen
            do {
                menu = try app.longPress(row)
            } catch where app.apple {
                // Isomer's Apple driver has no long press yet.
                withKnownIssue(Comment(rawValue: IsomerGap.appleLongPress.rawValue)) { Issue.record(error) }
                return
            }
            // The row's context menu, its items the screen's buttons.
            #expect(menu.element("Project Settings") != nil, "no context menu: \(menu.summary)")
            FeatureMapNode.project.expectShown(on: try app.tap("Project Settings"))
        }

        @Test("Sessions → Settings: tap settings")
        func opensSettings() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            FeatureMapNode.settings.expectShown(on: try app.tap("settings"))
        }

        @Test("Search results → Session chat: tap session-‹id›")
        func searchOpensASession() throws {
            let app = try VisorLaunch.fixture("search")
            defer { app.quit() }
            try app.screen { FeatureMapNode.search.isShown(on: $0) }
            // The row by its title and flag (Isomer's runtime) or its title
            // and state (the iPhone): not the message hit, "Agent · Offline sync".
            let row = try app.screen().element("Offline sync ⚑") != nil ? "Offline sync ⚑" : "Offline sync Working"
            let screen = try app.tap(id: "session-fixture-chat", else: row, .listRow)
            FeatureMapNode.chat.expectShown(on: screen)
            #expect(screen.titled("Offline sync"), "\(screen.summary)")
        }

        @Test("Search results → Session chat: tap message-hit")
        func searchOpensAMessage() throws {
            let app = try VisorLaunch.fixture("search")
            defer { app.quit() }
            try app.screen { FeatureMapNode.search.isShown(on: $0) }
            let screen = try app.tap(id: "message-hit", else: "Agent · Offline sync", .listRow)
            FeatureMapNode.chat.expectShown(on: screen)
            #expect(screen.titled("Offline sync"), "\(screen.summary)")
        }
    }
}

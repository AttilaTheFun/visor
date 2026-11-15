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
            FeatureMapNode.addComputer.expectShown(on: try app.tap("add-computer"))
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
            #expect(screen.texts.first == "Offline sync", "\(screen.summary)")
        }

        @Test("Session chat → Sessions: back (a phone's stack)")
        func backFromAChat() throws {
            let app = try VisorLaunch.fixture("chat")
            defer { app.quit() }
            try app.screen { FeatureMapNode.chat.isShown(on: $0) }
            FeatureMapNode.sessions.expectShown(on: try app.back())
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
            let screen = try app.tap(id: "session-fixture-chat", else: "Offline sync ⚑", .listRow)
            FeatureMapNode.chat.expectShown(on: screen)
            #expect(screen.texts.first == "Offline sync", "\(screen.summary)")
        }

        @Test("Search results → Session chat: tap message-hit")
        func searchOpensAMessage() throws {
            let app = try VisorLaunch.fixture("search")
            defer { app.quit() }
            try app.screen { FeatureMapNode.search.isShown(on: $0) }
            let screen = try app.tap(id: "message-hit", else: "Agent · Offline sync", .listRow)
            FeatureMapNode.chat.expectShown(on: screen)
            #expect(screen.texts.first == "Offline sync", "\(screen.summary)")
        }
    }
}

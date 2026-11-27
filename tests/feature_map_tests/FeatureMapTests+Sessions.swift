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
            // The bottom bar's compose, by its title.
            FeatureMapNode.newSession.expectShown(on: try app.tap("New session"))
        }

        @Test("Sessions → Session chat: tap session-‹id›")
        func opensAChat() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            let screen = try app.tap("session-fixture-chat")
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
            // The row's context menu, its items the screen's buttons (on the
            // iPhone too, since isomer#234's long press).
            let menu = try app.longPress("session-fixture-chat")
            #expect(menu.element("Project Settings") != nil, "no context menu: \(menu.summary)")
            FeatureMapNode.project.expectShown(on: try app.tap("Project Settings"))
        }

        @Test("Sessions → Sessions: longpress session-‹id›, tap “Migrate…”, “‹computer›'s Container”; and back, “‹computer›”")
        func movesIntoTheContainerAndBack() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            // The fixture's computer has a Sessions container that takes
            // sessions: Migrate… offers it.
            let menu = try app.longPress("session-fixture-chat")
            #expect(menu.element("Migrate…") != nil, "no Migrate… in the menu: \(menu.summary)")
            let places = try app.tap("Migrate…")
            #expect(places.element("Snapshot Mac's Container") != nil, "\(places.summary)")
            _ = try app.tap("Snapshot Mac's Container")
            let placed = try app.screen { $0.element("place-fixture-chat")?.label == "In the Sessions container" }
            FeatureMapNode.sessions.expectShown(on: placed)

            // In it, Migrate… offers its computer.
            _ = try app.longPress("session-fixture-chat")
            let back = try app.tap("Migrate…")
            #expect(back.element("Snapshot Mac") != nil && back.element("Snapshot Mac's Container") == nil, "\(back.summary)")
            _ = try app.tap("Snapshot Mac")
            let home = try app.screen { $0.element("place-fixture-chat")?.label != "In the Sessions container" }
            FeatureMapNode.sessions.expectShown(on: home)
        }

        /// The computer's sessions, top to bottom.
        private static func order(_ screen: HeadlessScreen) -> [String] {
            var seen: [String] = []
            for element in screen.elements {
                guard let id = element.id, id.hasPrefix("session-fixture-"), !seen.contains(id) else { continue }
                seen.append(id)
            }
            return seen.map { String($0.dropFirst("session-".count)) }
        }

        /// Pinned sessions list first, in the order they were pinned, then
        /// the rest, the latest first: the fixture's release notes pinned
        /// (marked `pinned-‹id›`) over the chat, the newest. Pin puts one
        /// after them; Unpin and Pin again, last of the pinned.
        @Test("Sessions → Sessions: longpress session-‹id›, tap “Pin”; “Unpin”, and “Pin” again")
        func pinsAndUnpins() throws {
            let app = try VisorLaunch.fixture("sessions")
            defer { app.quit() }
            let first = try app.screen { FeatureMapNode.sessions.isShown(on: $0) && Self.order($0).count == 4 }
            #expect(Self.order(first) == ["fixture-docs", "fixture-chat", "fixture-busy", "fixture-api"], "\(first.summary)")
            #expect(first.row("Release notes", marked: "pinned-fixture-docs", "Pinned"), "\(first.summary)")
            #expect(!first.row("Offline sync", marked: "pinned-fixture-chat", "Pinned"), "\(first.summary)")
            // A row is its title, its marks and its preview: no folder
            // (its details have it).
            #expect(first.rowTexts("Rate limits") == ["Rate limits", "The limiter now allows bursts of 20 per minute."], "\(first.summary)")
            #expect(!first.texts.contains("/Users/visor/Developer/api"), "no folder in the list: \(first.summary)")

            let menu = try app.longPress("session-fixture-api")
            #expect(menu.has(label: "Pin") && !menu.has(label: "Unpin"), "no Pin in the menu: \(menu.summary)")
            _ = try app.tap("Pin")
            let pinned = try app.screen { $0.row("Rate limits", marked: "pinned-fixture-api", "Pinned") }
            #expect(Self.order(pinned) == ["fixture-docs", "fixture-api", "fixture-chat", "fixture-busy"], "\(pinned.summary)")

            let pinnedMenu = try app.longPress("session-fixture-docs")
            #expect(pinnedMenu.has(label: "Unpin") && !pinnedMenu.has(label: "Pin"), "no Unpin in the menu: \(pinnedMenu.summary)")
            _ = try app.tap("Unpin")
            let unpinned = try app.screen { !$0.row("Release notes", marked: "pinned-fixture-docs", "Pinned") && $0.has(id: "session-fixture-docs") }
            #expect(Self.order(unpinned) == ["fixture-api", "fixture-chat", "fixture-busy", "fixture-docs"], "\(unpinned.summary)")

            _ = try app.longPress("session-fixture-docs")
            _ = try app.tap("Pin")
            let again = try app.screen { $0.row("Release notes", marked: "pinned-fixture-docs", "Pinned") }
            #expect(Self.order(again) == ["fixture-api", "fixture-docs", "fixture-chat", "fixture-busy"], "\(again.summary)")
            FeatureMapNode.sessions.expectShown(on: again)
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
            let screen = try app.tap("session-fixture-chat")
            FeatureMapNode.chat.expectShown(on: screen)
            #expect(screen.titled("Offline sync"), "\(screen.summary)")
        }

        @Test("Search results → Session chat: tap message-hit")
        func searchOpensAMessage() throws {
            let app = try VisorLaunch.fixture("search")
            defer { app.quit() }
            try app.screen { FeatureMapNode.search.isShown(on: $0) }
            let screen = try app.tap("message-hit")
            FeatureMapNode.chat.expectShown(on: screen)
            #expect(screen.titled("Offline sync"), "\(screen.summary)")
        }
    }
}

// Claude's sign-in from a session's chat (`/login`), in the sign-in-code
// fixture, whose session waits on it: the "Sign In to Claude" alert opens
// the page, and the code it shows is asked for in the sign-in code prompt
// (where nothing says Visor left for the page, as headless, a moment after
// it opens). Sent from the prompt or from the composer, the code reaches
// the sign-in as the composer's always has (AgentServerConnection
// .sendMessage → AgentServer.signIn): the fixture's computer answers that
// alone, the sign-in ended with a notice naming the code it was given (a
// message for the agent goes nowhere there).

import Foundation
import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Sign-in code prompt")
    struct SignIn {
        /// What the user pastes.
        static let code = "fixture-code#fixture-state"

        /// The fixture's notice once the sign-in has `code`
        /// (FixtureAgentServer.signIn).
        static func signedIn(with code: String) -> String { "Signed in to Claude again with the code \(code)." }

        /// The sign-in-code fixture, once its "Sign In to Claude" alert is up.
        private func offered() throws -> HeadlessApp {
            let app = try VisorLaunch.fixture("sign-in-code")
            let screen = try app.screen(within: 10) { Self.offersSignIn($0) }
            #expect(Self.offersSignIn(screen), "no sign-in offered: \(screen.summary)")
            return app
        }

        static func offersSignIn(_ screen: HeadlessScreen) -> Bool {
            screen.presented.contains { $0.title == "Sign In to Claude" } || screen.has(label: "Open Sign-In Page")
        }

        /// The prompt, from the alert: the page opened, and the code asked for.
        @discardableResult
        private func prompt(_ app: HeadlessApp) throws -> HeadlessScreen {
            try app.tap("Open Sign-In Page")
            let screen = try app.screen { FeatureMapNode.signInCode.isShown(on: $0) }
            FeatureMapNode.signInCode.expectShown(on: screen)
            return screen
        }

        /// Whether the session was told the sign-in had `code`.
        static func told(_ screen: HeadlessScreen, _ code: String) -> Bool {
            let words = signedIn(with: code)
            return screen.presented.contains { $0.message.contains(words) } || screen.shows(words)
        }

        /// The composer while the sign-in waits, by its placeholder.
        static let composer = "Paste the sign-in code"

        /// Sends `code` from the composer, and expects it to reach the sign-in.
        private func sendFromComposer(_ app: HeadlessApp) throws {
            try app.type(Self.composer, Self.code)
            try app.tap("Send")
            let told = try app.screen(within: 10) { Self.told($0, Self.code) }
            #expect(Self.told(told, Self.code), "the code didn't reach the sign-in: \(told.summary)")
        }

        @Test("Session chat ⇢ Sign-in code prompt: the agent asks for Claude's sign-in (tap “Open Sign-In Page”)")
        func asks() throws {
            let app = try offered()
            defer { app.quit() }
            let screen = try prompt(app)
            // Send waits for a code: listed disabled, or not at all.
            let send = screen.element("sign-in-send")
            #expect(send == nil || send?.disabled == true, "Send with no code: \(screen.summary)")
        }

        @Test("Sign-in code prompt → Session chat: type sign-in-code, tap sign-in-send")
        func send() throws {
            let app = try offered()
            defer { app.quit() }
            try prompt(app)
            try app.type("sign-in-code", Self.code)
            try app.tap("sign-in-send")
            let told = try app.screen(within: 10) { Self.told($0, Self.code) }
            #expect(Self.told(told, Self.code), "the code didn't reach the sign-in: \(told.summary)")
            #expect(!FeatureMapNode.signInCode.isShown(on: told), "the prompt is still up: \(told.summary)")
            // The notice put away: the chat, with the code asked for no more.
            let chat = try app.tap("OK")
            FeatureMapNode.chat.expectShown(on: try app.screen { FeatureMapNode.chat.isShown(on: $0) })
            #expect(!FeatureMapNode.signInCode.isShown(on: chat), "asked again once sent: \(chat.summary)")
        }

        @Test("Sign-in code prompt → Session chat: tap sign-in-cancel; the composer still takes the code")
        func cancel() throws {
            let app = try offered()
            defer { app.quit() }
            try prompt(app)
            let chat = try app.tap("sign-in-cancel")
            #expect(!FeatureMapNode.signInCode.isShown(on: chat), "the prompt is still up: \(chat.summary)")
            FeatureMapNode.chat.expectShown(on: try app.screen { FeatureMapNode.chat.isShown(on: $0) })
            // The sign-in still waits: its code goes from the composer.
            try sendFromComposer(app)
        }

        @Test("Sign-in code prompt, again: leave Visor and come back (scene background, then active) while the code is awaited, not once it's sent")
        func comesBack() throws {
            let app = try offered()
            defer { app.quit() }
            try prompt(app)
            let chat = try app.tap("sign-in-cancel")
            #expect(!FeatureMapNode.signInCode.isShown(on: chat), "the prompt is still up: \(chat.summary)")
            // Away (to the sign-in page, say) and back: the code is asked
            // for again.
            try app.scene(.background)
            try app.scene(.active)
            let again = try app.screen { FeatureMapNode.signInCode.isShown(on: $0) }
            FeatureMapNode.signInCode.expectShown(on: again)
            // Sent from the prompt, it isn't asked for on the next return.
            try app.type("sign-in-code", Self.code)
            try app.tap("sign-in-send")
            let told = try app.screen(within: 10) { Self.told($0, Self.code) }
            #expect(Self.told(told, Self.code), "the code didn't reach the sign-in: \(told.summary)")
            try app.tap("OK")
            try app.scene(.background)
            try app.scene(.active)
            Thread.sleep(forTimeInterval: 2)
            let back = try app.screen()
            #expect(!FeatureMapNode.signInCode.isShown(on: back), "asked again once sent: \(back.summary)")
        }

        @Test("Session chat: “Later”, then the code from the composer")
        func composerRoute() throws {
            let app = try offered()
            defer { app.quit() }
            try app.tap("Later")
            FeatureMapNode.chat.expectShown(on: try app.screen { FeatureMapNode.chat.isShown(on: $0) })
            // Not opened from here: the code isn't asked for.
            Thread.sleep(forTimeInterval: 2)
            #expect(!FeatureMapNode.signInCode.isShown(on: try app.screen()), "asked for a page not opened")
            try sendFromComposer(app)
        }
    }
}

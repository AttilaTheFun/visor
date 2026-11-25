// The Sessions container's Claude credential, on a computer's page in
// Settings (docs/containers.md, "Claude's credential"): its state, set or
// not (its presence alone); Sign In to Claude…, a token refused for its
// shape with the sheet still open, then one kept; and Sign Out.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Sessions container's Claude credential")
    struct ContainerCredential {
        /// What the state says: "Set" or "Not set".
        static func state(_ screen: HeadlessScreen) -> String? {
            screen.elements.first { $0.id == "container-claude-state" }.map { $0.label.isEmpty ? ($0.value ?? "") : $0.label }
        }

        /// The fixture's computer's page, its credential's state said.
        private func computer() throws -> HeadlessApp {
            let app = try VisorLaunch.fixture("sessions")
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            try app.tap("settings")
            try app.tap("settings-computer-Snapshot Mac")
            try app.screen { $0.has(id: "container-sign-in") }
            return app
        }

        @Test("Computer settings → Sign In to Claude: tap container-sign-in")
        func opensTheSheet() throws {
            let app = try computer()
            defer { app.quit() }
            let page = try app.screen()
            FeatureMapNode.computer.expectShown(on: page)
            #expect(Self.state(page) == "Not set", "\(page.summary)")
            #expect(!page.has(id: "container-claude-sign-out"), "nothing to sign out of")
            try app.tap("container-sign-in")
            let sheet = try app.screen { FeatureMapNode.claudeSignIn.isShown(on: $0) }
            FeatureMapNode.claudeSignIn.expectShown(on: sheet)
            #expect(sheet.shows("claude setup-token"), "what to run, and where: \(sheet.summary)")
        }

        @Test("Sign In to Claude → Computer settings: type container-claude-token, tap container-claude-save; and Sign Out")
        func keepsTheCredential() throws {
            let app = try computer()
            defer { app.quit() }
            try app.tap("container-sign-in")
            try app.screen { FeatureMapNode.claudeSignIn.isShown(on: $0) }
            // Not a setup-token's: refused, saying so, the sheet still open.
            try app.type("container-claude-token", "sk-live-not-one")
            try app.tap("container-claude-save")
            let refused = try app.screen { $0.has(id: "container-claude-error") }
            FeatureMapNode.claudeSignIn.expectShown(on: refused)
            #expect(refused.elements.contains { $0.id == "container-claude-error" && $0.label.contains("sk-ant-oat") }
                    || refused.shows("sk-ant-oat"), "\(refused.summary)")
            // One that is: kept, the sheet closed, the state Set.
            try app.type("container-claude-token", "sk-ant-oat01-fixture-token")
            try app.tap("container-claude-save")
            let kept = try app.screen { !FeatureMapNode.claudeSignIn.isShown(on: $0) && Self.state($0) == "Set" }
            #expect(Self.state(kept) == "Set", "\(kept.summary)")
            #expect(!kept.shows("sk-ant-oat01-fixture-token"), "never shown again")
            // Sign Out: not set again.
            try app.tap("container-claude-sign-out")
            let out = try app.screen { Self.state($0) == "Not set" }
            #expect(Self.state(out) == "Not set", "\(out.summary)")
        }
    }
}

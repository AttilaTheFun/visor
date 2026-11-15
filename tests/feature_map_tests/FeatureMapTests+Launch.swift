// Launch's three ways out, and the onboarding's and the account sign-in's.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Launch, onboarding, sign-in")
    struct Launch {
        @Test("Launch → Onboarding: no computer yet")
        func noComputerOnboards() throws {
            let app = try VisorLaunch.empty()
            defer { app.quit() }
            FeatureMapNode.onboarding.expectShown(on: try app.screen())
        }

        @Test("Launch → Sign in to Visor: the app's account signed out")
        func signedOutAccountSignsIn() throws {
            let app = try VisorLaunch.signedOutAccount()
            defer { app.quit() }
            FeatureMapNode.signIn.expectShown(on: try app.screen())
        }

        @Test("Launch → Sessions: otherwise")
        func otherwiseSessions() throws {
            let app = try VisorLaunch.fixture()
            defer { app.quit() }
            let screen = try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            FeatureMapNode.sessions.expectShown(on: screen)
            #expect(screen.texts.contains("Snapshot Mac"))
        }

        @Test("Onboarding → Add Computer: tap add-computer")
        func onboardingAddsAComputer() throws {
            let app = try VisorLaunch.empty()
            defer { app.quit() }
            FeatureMapNode.addComputer.expectShown(on: try app.tap("add-computer"))
        }

        @Test("Onboarding → Settings: tap settings")
        func onboardingOpensSettings() throws {
            let app = try VisorLaunch.empty()
            defer { app.quit() }
            FeatureMapNode.settings.expectShown(on: try app.tap("settings"))
        }

        @Test("Sign in to Visor → Sessions: tap account-sign-in")
        func signInShowsTheAccountsComputers() throws {
            let app = try VisorLaunch.signedOutAccount()
            defer { app.quit() }
            try app.tap("account-sign-in")
            // The fixture's sign-in takes a moment; then its three computers.
            let screen = try app.screen { $0.texts.contains("Build Box") }
            FeatureMapNode.sessions.expectShown(on: screen)
            #expect(screen.texts.contains("Build Box"), "\(screen.summary)")
        }
    }
}

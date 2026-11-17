// Add Computer and the MultiPass sign-in beside it.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Add Computer")
    struct AddComputer {
        @Test("Add Computer → Sessions: type host, type password, tap connect")
        func connects() throws {
            // From the onboarding, as a first computer is added: the
            // computer is kept and the list shows it, whether or not it
            // answers (the headless client has no network).
            let app = try VisorLaunch.empty()
            defer { app.quit() }
            try app.tap("add-computer")
            try app.type("host", "http://192.168.1.20:7433")
            // The password's field is there once an address is.
            try app.type("password", "secret")
            let screen = try app.tap("connect")
            FeatureMapNode.sessions.expectShown(on: screen)
            #expect(!screen.shows("Welcome to Visor"), "\(screen.summary)")
        }

        @Test("Add Computer → Sign in to a MultiPass: tap runner")
        func signsInToAMultiPass() throws {
            let app = try VisorLaunch.fixture("connect")
            defer { app.quit() }
            try app.screen { FeatureMapNode.addComputer.isShown(on: $0) }
            FeatureMapNode.runner.expectShown(on: try app.tap("runner"))
        }

        @Test("Sign in to a MultiPass → Add Computer: tap use-connection-code")
        func backToAConnectionCode() throws {
            let app = try VisorLaunch.fixture("runner")
            defer { app.quit() }
            try app.screen { FeatureMapNode.runner.isShown(on: $0) }
            let screen = try app.tap("use-connection-code")
            FeatureMapNode.addComputer.expectShown(on: screen)
        }

        @Test("Add Computer → back where it was: dismiss")
        func dismisses() throws {
            let app = try VisorLaunch.fixture("connect")
            defer { app.quit() }
            try app.screen { FeatureMapNode.addComputer.isShown(on: $0) }
            FeatureMapNode.sessions.expectShown(on: try app.dismiss())
        }
    }
}

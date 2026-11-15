// Settings, a sheet on a phone's width.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Settings")
    struct Settings {
        private func settings() throws -> HeadlessApp {
            let app = try VisorLaunch.fixture("sessions")
            try app.screen { FeatureMapNode.sessions.isShown(on: $0) }
            try app.tap("settings")
            return app
        }

        @Test("Settings → Computer settings: tap settings-computer-‹name›")
        func computer() throws {
            let app = try settings()
            defer { app.quit() }
            FeatureMapNode.computer.expectShown(on: try app.tap("settings-computer-Snapshot Mac"))
        }

        @Test("Settings → Add Computer: tap settings-add-computer")
        func addComputer() throws {
            let app = try settings()
            defer { app.quit() }
            FeatureMapNode.addComputer.expectShown(on: try app.tap("settings-add-computer"))
            // Over Settings: put away, Settings again.
            FeatureMapNode.settings.expectShown(on: try app.dismiss())
        }

        @Test("Settings → Sessions: tap settings-done")
        func done() throws {
            let app = try settings()
            defer { app.quit() }
            FeatureMapNode.sessions.expectShown(on: try app.tap("settings-done"))
        }
    }
}

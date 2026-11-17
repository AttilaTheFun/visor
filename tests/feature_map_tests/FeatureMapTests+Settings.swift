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
            FeatureMapNode.computer.expectShown(on: try app.tap(id: "settings-computer-Snapshot Mac", else: "Snapshot Mac, Connected"))
        }

        @Test("Settings → Add Computer: tap settings-add-computer")
        func addComputer() throws {
            let app = try settings()
            defer { app.quit() }
            // A sheet over Settings' sheet, at once: on the iPhone too, where
            // it is presented from Settings' sheet, not from under it.
            FeatureMapNode.addComputer.expectShown(on: try app.tap(id: "settings-add-computer", else: "Add Computer…"))
            // Cancel: Settings again, still open.
            let screen = try app.tap("Cancel")
            FeatureMapNode.settings.expectShown(on: screen)
            #expect(!FeatureMapNode.addComputer.isShown(on: screen), "\(screen.summary)")
        }

        @Test("Settings → Sessions: tap settings-done")
        func done() throws {
            let app = try settings()
            defer { app.quit() }
            FeatureMapNode.sessions.expectShown(on: try app.tap(id: "settings-done", else: "Done"))
        }
    }
}

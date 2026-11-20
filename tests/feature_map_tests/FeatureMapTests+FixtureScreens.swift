// Each node a fixture screen opens (the "Fixture screen" column of
// FEATURE_MAP.md's table), opened at launch and recognised.

import IsomerHeadless
import Testing

extension FeatureMapTests {
    @Suite("Fixture screens")
    struct FixtureScreens {
        static let screens: [(String, FeatureMapNode)] = [
            ("onboarding", .onboarding),
            ("sessions", .sessions),
            ("machines", .sessions),
            ("search", .search),
            ("connect", .addComputer),
            ("new-session", .newSession),
            ("restore", .restore),
            ("chat", .chat),
            ("goal", .chat),
            ("earlier", .chat),
            ("commands", .chat),
            ("responding", .chat),
            ("chat", .approval),
            ("question", .question),
            ("models", .model),
            ("inspector", .details),
            ("settings", .settings),
        ]

        @Test("A fixture screen opens its node", arguments: screens)
        func opens(screen: String, node: FeatureMapNode) throws {
            let app = try VisorLaunch.fixture(screen)
            defer { app.quit() }
            // Some open a moment after launch (the inspector, the models).
            node.expectShown(on: try app.screen { node.isShown(on: $0) })
        }
    }
}

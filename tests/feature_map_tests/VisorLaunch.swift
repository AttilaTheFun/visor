// How a feature map test starts Visor: the client built headless
// (//applications/visor_headless) from the test's runfiles, or, when the
// environment names one of Isomer's launchers (ISOMER_HEADFUL_LAUNCHER,
// @isomer//drive/launchers), a client built with --config=drive on a
// simulator, an emulator or in a browser, dialling the test's hub. The test
// bodies are the same either way.

import Foundation
import IsomerHeadless

/// What a test launches: the fixture (a screen of it, or the app's own
/// first screen), or an empty client, at a phone's width or a regular one.
struct VisorLaunch {
    /// The launcher the environment names, if any: headful.
    static var launcher: String? {
        let launcher = ProcessInfo.processInfo.environment["ISOMER_HEADFUL_LAUNCHER"] ?? ""
        return launcher.isEmpty ? nil : launcher
    }

    /// Whether the client is the headless one, whose width a test chooses.
    static var headless: Bool { launcher == nil }

    /// The width a test needs. Headless, the window is made so (Isomer's
    /// ISO_HEADLESS_WIDTH and ISO_HEADLESS_HEIGHT); headful, the device is
    /// what it is (the regular width's tests are headless alone for now).
    enum Width {
        /// An iPhone's: one column at a time.
        case compact
        /// An iPad's or a Mac's window: the list and the chat side by side.
        case regular

        var size: (width: Int, height: Int) {
            switch self {
            case .compact: (390, 844)
            case .regular: (1180, 820)
            }
        }
    }

    /// The canned computer (VisorFixture), opened on `screen` ("" for the
    /// app's own first screen: Sessions).
    static func fixture(_ screen: String = "", width: Width = .compact) throws -> HeadlessApp {
        var environment = ["fixture": "snapshot"]
        if !screen.isEmpty { environment["fixture.screen"] = screen }
        return try launch(environment, width: width)
    }

    /// A client with no computer: the onboarding.
    static func empty(width: Width = .compact) throws -> HeadlessApp {
        try launch([:], width: width)
    }

    /// A client whose app has an account (the fixture's, FixtureAccount),
    /// signed out: its sign-in.
    static func signedOutAccount(width: Width = .compact) throws -> HeadlessApp {
        try launch(["account": "fixture"], width: width)
    }

    /// `settings` are the client's settings for this launch, by their own
    /// names (`fixture`, `fixture.screen`, `account`): the headless client's
    /// environment, Android's launch intent's extras.
    private static func launch(_ settings: [String: String], width: Width) throws -> HeadlessApp {
        if let launcher {
            return try HeadlessApp(launcher: launcher, environment: settings)
        }
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        let size = width.size
        return try HeadlessApp(
            executable: "\(root)/applications/visor_headless/visor_headless",
            environment: settings.merging(["ISO_HEADLESS_WIDTH": "\(size.width)", "ISO_HEADLESS_HEIGHT": "\(size.height)"]) { $1 })
    }
}

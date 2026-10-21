import UIKit
import XCTest

/// Blue Visor's fixture screens in the simulator, pictured as red Visor's
/// probe pictures red's (visor's tests/ios_probe, `fixtureShots`): the same
/// screens, launch arguments, turns and picture taking, so the review
/// server can hold each of blue's pictures against red's same-named one.
/// The pictures go to /private/tmp/visor_isomer_fixture (the simulator
/// shares this Mac's disk) as fixture-<screen>.png; tools/isomer/snapshots/
/// snapshots.py's `ios` and `ios-landscape` targets run it.
@MainActor
final class BlueFixtureShots: XCTestCase {
    private let outDir = "/private/tmp/visor_isomer_fixture"

    func testFixtureScreens() throws {
        fixtureShots(.portrait)
    }

    func testFixtureScreensLandscape() throws {
        fixtureShots(.landscapeLeft)
    }

    /// Upright again after: a simulator left on its side gives whatever
    /// runs on it next a landscape phone's insets.
    override nonisolated func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
    }

    private func fixtureShots(_ orientation: UIDeviceOrientation) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = orientation
        for screen in ["sessions", "chat", "question", "goal", "inspector", "models", "search", "connect", "new-session", "commands", "earlier"] {
            let app = XCUIApplication()
            app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", screen]
            app.launch()
            // Turned again once the app is up, as red's are: one launched
            // while the phone lies on its side can come up in portrait.
            if orientation != .portrait {
                XCUIDevice.shared.orientation = .portrait
                XCUIDevice.shared.orientation = orientation
            }
            // The guest's first frame: the reactor is loaded and started
            // before anything is drawn, which a native launch doesn't wait
            // for.
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 60)
            if screen == "search" {
                XCTAssertTrue(app.staticTexts["Messages"].waitForExistence(timeout: 60), "the search found no messages")
            }
            Thread.sleep(forTimeInterval: 6)
            shot(app, "fixture-" + screen)
            app.terminate()
        }
    }

    /// The screen, upright, as red's probe takes it: in landscape the
    /// screen's picture (the app's comes out as its portrait layout in half
    /// a landscape frame on iOS 27's simulator), the app's in portrait.
    private func shot(_ app: XCUIApplication, _ name: String) {
        let picture = (XCUIDevice.shared.orientation.isLandscape ? XCUIScreen.main.screenshot() : app.screenshot()).image
        let format = UIGraphicsImageRendererFormat()
        format.scale = picture.scale
        let sideways = XCUIDevice.shared.orientation == .landscapeLeft && picture.size.width < picture.size.height
        let size = sideways ? CGSize(width: picture.size.height, height: picture.size.width) : picture.size
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if sideways {
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.rotate(by: -.pi / 2)
            }
            picture.draw(at: .zero)
        }
        try? upright.pngData()?.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        let kept = XCTAttachment(image: upright)
        kept.name = name
        kept.lifetime = .keepAlways
        add(kept)
    }
}

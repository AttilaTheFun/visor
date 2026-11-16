// What the feature map's tests ask of a driven app beyond Isomer's
// commands: which driver it is on, and a screen waited for.

import Foundation
import IsomerHeadless

extension HeadlessApp {
    /// Whether the app is on Apple's SwiftUI, driven by Isomer's Apple
    /// driver (the iPhone, the Mac).
    var apple: Bool {
        let platform = (try? info().platform.lowercased()) ?? ""
        return platform == "ios" || platform == "macos"
    }

    /// The screen once `shown` holds of it, asked again until `timeout`
    /// seconds have gone (a fixture's screen opens a moment after launch;
    /// a sign-in takes a moment).
    @discardableResult
    func screen(within timeout: Double = 5, until shown: (HeadlessScreen) -> Bool) throws -> HeadlessScreen {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        var screen = try screen()
        while !shown(screen), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            screen = try self.screen()
        }
        return screen
    }
}

// What the feature map's tests ask of a driven app beyond Isomer's
// commands: a screen waited for.

import Foundation
import IsomerHeadless

extension HeadlessApp {
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

// Taking an edge of the feature map by the identifier FEATURE_MAP.md names,
// and by a label where Isomer's driver doesn't show that identifier yet.

import Foundation
import IsomerHeadless
import Testing

extension HeadlessApp {
    /// Taps `id`; where the screen lists no element with that identifier,
    /// `label` instead, recording `gap` as a known issue.
    @discardableResult
    func tap(id: String, else label: String, _ gap: IsomerGap) throws -> HeadlessScreen {
        try tap(try target(id: id, else: label, gap))
    }

    /// `id` if the screen lists an element with that identifier, else
    /// `label`, with `gap` recorded as a known issue.
    func target(id: String, else label: String, _ gap: IsomerGap) throws -> String {
        let screen = try screen()
        if screen.elements.contains(where: { $0.id == id }) { return id }
        withKnownIssue(Comment(rawValue: gap.rawValue)) {
            Issue.record("no element \(id): found by \"\(label)\"")
        }
        return label
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

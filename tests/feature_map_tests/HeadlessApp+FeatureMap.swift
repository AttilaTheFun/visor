// Taking an edge of the feature map by the identifier FEATURE_MAP.md names,
// and by a label where Isomer's driver doesn't show that identifier yet.

import Foundation
import IsomerHeadless
import Testing

extension HeadlessApp {
    /// Taps `id`; where the screen lists no element with that identifier,
    /// `label` instead, recording `gap` as a known issue (on the iPhone,
    /// IsomerGap.appleIdentifier).
    @discardableResult
    func tap(id: String, else label: String, _ gap: IsomerGap = .appleIdentifier) throws -> HeadlessScreen {
        try tap(try target(id: id, else: label, gap))
    }

    /// Types into `id`'s field, or `label`'s, as `tap(id:else:)` finds it.
    @discardableResult
    func type(id: String, else label: String, _ text: String, _ gap: IsomerGap = .appleIdentifier) throws -> HeadlessScreen {
        try type(try target(id: id, else: label, gap), text)
    }

    /// Whether the app is on Apple's SwiftUI, driven by Isomer's Apple
    /// driver (the iPhone, the Mac).
    var apple: Bool {
        let platform = (try? info().platform.lowercased()) ?? ""
        return platform == "ios" || platform == "macos"
    }

    /// `id` if the screen lists an element with that identifier, else
    /// `label`, with `gap` recorded as a known issue: on Apple's platforms,
    /// where Isomer's Apple driver lists few identifiers,
    /// IsomerGap.appleIdentifier whatever the gap Isomer's runtime has.
    func target(id: String, else label: String, _ gap: IsomerGap) throws -> String {
        let screen = try screen()
        if screen.elements.contains(where: { $0.id == id }) { return id }
        let known = apple ? IsomerGap.appleIdentifier : gap
        withKnownIssue(Comment(rawValue: known.rawValue)) {
            Issue.record("no element \(id): found by \"\(label)\"")
        }
        return label
    }

    /// Puts the sheet away: `dismiss`, or where the driver can't
    /// (IsomerGap.appleDismiss), the sheet's own Cancel, Done or close.
    @discardableResult
    func putAway() throws -> HeadlessScreen {
        do {
            return try dismiss()
        } catch {
            let screen = try screen()
            guard let button = ["Cancel", "Done", "close"].first(where: { label in screen.elements.contains { $0.label == label } }) else {
                throw error
            }
            withKnownIssue(Comment(rawValue: IsomerGap.appleDismiss.rawValue)) {
                Issue.record("dismiss: \(error); put away by \"\(button)\"")
            }
            return try tap(button)
        }
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

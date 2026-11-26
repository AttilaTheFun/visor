// The release's proof, through Isomer's driver: the fixture's screens a
// release is compared by (tools/ci/proof_ios.sh's SCREENS, snapshots.py's
// for Android, proof_mac.sh's), each pictured by the platform's launcher
// (HeadlessApp.picture: `ios/phone/chat`, `ios/phone-landscape/chat`,
// `android/phone/chat`, `macos/window/chat`). One launch of the fixture
// walks FEATURE_MAP.md's edges to every screen it reaches (Sessions, Add
// Computer, New Session, a chat, its details, the goal's chat); a screen
// whose fixture's data differs (the question waiting, the computers'
// machines, the earlier rows)
// or that the fixture opens without a tap (the model sheet over the
// chat's approval, "/" in the composer, the search's words: no caret
// blinking in the field) is a launch of its own on that screen.
//
//   VISOR_PROOF_SCREENS      the screens, in order (space-separated)
//   VISOR_PROOF_ORIENTATION  portrait (the default) or landscape: the
//                            iPhone's app turns itself (its
//                            fixture.orientation); Android's emulator is
//                            turned before the run
//   ISOMER_PROOF             where the pictures go (screens/<id>.png)
//   VISOR_PROOF_SETTLE_SECONDS  how long a screen is given to hold still
//                            before its picture (default 5: a slow
//                            simulator's sheets and turns take longer)
//
// A screen is pictured once it is drawn, not only listed: its node shown,
// what its own view lists there (a chat's rows, the commands' popover),
// and on the iPhone its sheet risen onto the screen and held there, and on
// its side the window turned (`arrive`); then two pictures in a row the
// same (HeadlessApp.steadyPicture). Each waits for what the screen shows,
// not for a time: on GitHub's Macs no longer than before, and as long as a
// slow simulator takes.
//
// Headful alone (//tests/feature_map_tests:feature_map_proof_<platform>);
// headless, there is nothing to picture and it isn't run.

import Foundation
import IsomerHeadless
import Testing

@Suite("The proof", .serialized, .enabled(if: !VisorLaunch.headless, "the proof's pictures are a headful app's"))
struct FeatureMapProof {
    /// The screens asked for.
    static var screens: [String] {
        (ProcessInfo.processInfo.environment["VISOR_PROOF_SCREENS"] ?? "").split(separator: " ").map(String.init)
    }

    /// The fixture's settings for this run: the iPhone's app on its side.
    static var settings: [String: String] {
        ProcessInfo.processInfo.environment["VISOR_PROOF_ORIENTATION"] == "landscape" ? ["fixture.orientation": "landscape"] : [:]
    }

    /// Whether the app is the iPhone's (Isomer's iOS launcher): where the
    /// driver lists a sheet while it is still below the screen, and the
    /// app turns itself on its side a moment after it opens.
    static var iPhone: Bool {
        (VisorLaunch.launcher.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "").hasPrefix("ios")
    }

    /// What a screen's own view lists once it is drawn, past its node: the
    /// commands' popover, both of the fixture's slash commands; a chat's
    /// rows (VisorFixture's), which AgentUI draws at opacity 0 under its
    /// held empty state until the thread has settled at its end
    /// (TranscriptView's reveal), and which the driver lists only then
    /// (SwiftUI leaves a view at opacity 0 out of accessibility, and the
    /// driver a UIKit view at alpha 0). A row the list of Sessions doesn't
    /// show as a preview, where it is beside the chat.
    static func drawn(_ screen: String, on shown: HeadlessScreen) -> Bool {
        if screen == "commands" {
            return ["/compact", "/goal"].allSatisfy { command in
                shown.elements.contains { $0.id == "suggestion-" + command || $0.label.hasPrefix(command) }
            }
        }
        let rows: [String] = switch screen {
        case "chat": ["The weather app loses rows when the phone goes offline", "Rows now sync in the background, and the banner"]
        case "goal": ["Start on this."]
        case "earlier": ["Start on this.", "Earlier row"]
        default: []
        }
        return rows.isEmpty || rows.contains { row in shown.shows(row) || shown.elements.contains { $0.label.contains(row) } }
    }

    /// The elements of a screen's own view that are looked at on the
    /// iPhone until they are on the screen and held still, by identifier
    /// or label: a sheet's (the first of them listed), which the driver
    /// lists while the sheet is still below the screen; the commands'
    /// popover's rows. Each is near the top, and wide or on the left:
    /// accessibility's frames are in the upright device's coordinates on
    /// an app that turns itself, where a narrow element on the window's
    /// right, below it, falls inside the window's bounds (`hold`), and a
    /// sheet on its side is shorter than its form.
    static func held(_ screen: String, on shown: HeadlessScreen) -> [String] {
        let elements: [String] = switch screen {
        case "connect": ["host"]
        case "new-session": ["Cancel", "conversation", "start"]
        case "question": ["question-skip", "question-send"]
        case "models": ["approval-Auto Approve", "all-models"]
        case "inspector": ["details-title", "details-done"]
        case "settings": ["settings-appearance"]
        case "search": ["message-hit"]
        case "commands": ["suggestion-/compact", "suggestion-/goal"]
        default: []
        }
        let listed = elements.filter { shown.has(id: $0) || shown.has(label: $0) }
        return screen == "commands" ? listed : Array(listed.prefix(1))
    }

    /// How a screen is told once its own launch has opened it.
    static func node(_ screen: String) -> FeatureMapNode? {
        switch screen {
        case "onboarding": .onboarding
        case "sessions", "machines": .sessions
        case "chat", "goal", "earlier", "commands": .chat
        case "question": .question
        case "inspector": .details
        case "models": .model
        case "search": .search
        case "connect": .addComputer
        case "new-session": .newSession
        case "settings": .settings
        default: nil
        }
    }

    @Test("Each of the proof's screens, pictured")
    func pictures() throws {
        let wanted = Self.screens
        try #require(!wanted.isEmpty, "VISOR_PROOF_SCREENS names no screen")
        var taken = Set<String>()
        let start = ContinuousClock.now

        // One launch, walking the map: where a step fails, the rest of its
        // screens are a launch each, below.
        do {
            try walk(wanted: Set(wanted), taken: &taken)
            print("[proof] the walk: \(taken.count) screens in \(ContinuousClock.now - start)")
        } catch {
            Issue.record(error, "the walk stopped: its remaining screens are opened by their own launches")
        }
        // A launch each for the rest, in the order asked.
        for screen in wanted where !taken.contains(screen) {
            let app = try VisorLaunch.fixture(screen, settings: Self.settings)
            defer { app.quit() }
            try arrive(app, at: screen, timeout: screen == "search" ? 30 : 15)
            try shoot(app, screen)
            taken.insert(screen)
        }
        print("[proof] \(taken.count) screens in \(ContinuousClock.now - start)")
    }

    /// The fixture's Sessions, and the screens reached from it by a tap.
    private func walk(wanted: Set<String>, taken: inout Set<String>) throws {
        let reached = ["sessions", "connect", "new-session", "chat", "inspector", "goal"]
        guard !wanted.isDisjoint(with: reached) else { return }
        let app = try VisorLaunch.fixture("sessions", settings: Self.settings)
        defer { app.quit() }
        func take(_ screen: String) throws {
            guard wanted.contains(screen) else { return }
            try shoot(app, screen)
            taken.insert(screen)
        }
        try arrive(app, at: "sessions")
        try take("sessions")

        // Sessions → Add Computer; put away.
        if wanted.contains("connect") {
            try app.tap("add-computer")
            try arrive(app, at: "connect")
            try take("connect")
            try app.dismiss()
            try arrive(app, at: "sessions")
        }

        // Sessions → New Session (the bottom bar's compose); put away.
        if wanted.contains("new-session") {
            try app.tap("New session")
            try arrive(app, at: "new-session")
            try take("new-session")
            try app.dismiss()
            try arrive(app, at: "sessions")
        }

        // Sessions → the chat → its details, and back to Sessions.
        if wanted.contains("chat") || wanted.contains("inspector") {
            try app.tap("session-fixture-chat")
            try arrive(app, at: "chat")
            try take("chat")
            if wanted.contains("inspector") {
                try app.tap("session-title")
                try arrive(app, at: "inspector")
                try take("inspector")
                try app.tap("details-done")
                try arrive(app, at: "chat")
            }
            // A phone's stack goes back to Sessions; a wide window (Android
            // on its side) has the list beside the chat already.
            let screen = try app.screen()
            let listed = screen.shows("Release notes") || screen.elements.contains { $0.id == "session-fixture-docs" || $0.label.contains("Release notes") }
            if !listed {
                try app.back()
                try arrive(app, at: "sessions")
            }
        }

        // Sessions → the goal's chat.
        if wanted.contains("goal") {
            try app.tap("session-fixture-docs")
            try arrive(app, at: "goal")
            try take("goal")
        }
    }

    /// Waits for `screen`'s node (when it has one) and what its own view
    /// lists, then on the iPhone for it to be drawn (`hold`), recording an
    /// issue if it never is; its picture is taken all the same.
    private func arrive(_ app: HeadlessApp, at screen: String, timeout: Double = 15) throws {
        guard let node = Self.node(screen) else {
            Thread.sleep(forTimeInterval: 4)
            return
        }
        // The commands' chat: its slash commands offered, over it on the
        // iPhone (a popover, all the driver lists while it's open).
        let isShown = { (shown: HeadlessScreen) in
            (node.isShown(on: shown) || (screen == "commands" && shown.elements.contains { $0.label.hasPrefix("/goal") }))
                && Self.drawn(screen, on: shown)
        }
        let start = ContinuousClock.now
        let shown = try app.screen(within: timeout) { isShown($0) }
        #expect(isShown(shown), "\(screen): not \(node.rawValue), or not its own rows or commands yet: \(shown.summary)")
        if Self.iPhone { try hold(app, screen, Self.held(screen, on: shown), timeout: timeout) }
        print("[proof] \(screen): there in \(ContinuousClock.now - start)")
    }

    /// A frame as the driver's `inspect` gives it (its `frame`: `x y width
    /// height` in points, accessibility's).
    private struct Frame: Equatable {
        let x, y, width, height: Double

        init?(_ text: String?) {
            let numbers = (text ?? "").split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
            x = numbers[0]
            y = numbers[1]
            width = numbers[2]
            height = numbers[3]
        }

        /// Inside a `width` by `height` screen, either way round: the
        /// window's, or on an app that turns itself, the upright device's
        /// (a point's rounding aside).
        func inside(width: Double, height: Double) -> Bool {
            guard x >= -1, y >= -1 else { return false }
            let right = x + self.width - 1, bottom = y + self.height - 1
            return (right <= width && bottom <= height) || (right <= height && bottom <= width)
        }
    }

    /// Waits, within `timeout` seconds, for the iPhone's screen as it is
    /// drawn: on its side, the window turned (wider than it is tall: the
    /// app turns itself a moment after it opens, and HeadlessApp.picture
    /// names a picture by it); and each of `elements` on the screen, its
    /// frame where it was the look before (a sheet listed before it has
    /// risen, or on its way up or round, is below the screen or moving).
    /// Where the driver gives no frame, the node alone, as before.
    private func hold(_ app: HeadlessApp, _ screen: String, _ elements: [String], timeout: Double) throws {
        let landscape = ProcessInfo.processInfo.environment["VISOR_PROOF_ORIENTATION"] == "landscape"
        guard landscape || !elements.isEmpty else { return }
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        var size: HeadlessInfo?
        var before: [Frame]?
        var why = ""
        repeat {
            // The window's size, until it has turned (then it stays).
            if size == nil {
                let info = try app.info()
                if landscape, info.width <= info.height {
                    why = "the window not turned yet (\(Int(info.width))×\(Int(info.height)))"
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                size = info
                if elements.isEmpty { return }
            }
            guard let width = size?.width, let height = size?.height else { continue }
            // Each `inspect` reads the screen once the driver has seen it
            // settle: two looks a settling apart.
            var frames: [Frame] = []
            for element in elements {
                guard let inspection = try? app.inspect(element) else {
                    why = "\(element) not listed"
                    break
                }
                guard let frame = Frame(inspection.params["frame"]) else {
                    print("[proof] \(screen): no frame of \(element) (\(inspection.params["frame"] ?? "none")): its node alone")
                    return
                }
                guard frame.inside(width: width, height: height) else {
                    why = "\(element) at \(frame), off the \(Int(width))×\(Int(height)) screen"
                    break
                }
                frames.append(frame)
            }
            guard frames.count == elements.count else {
                before = nil
                continue
            }
            if frames == before { return }
            why = "\(elements.joined(separator: ", ")) moving: \(before.map { "\($0)" } ?? "") to \(frames)"
            before = frames
        } while ContinuousClock.now < deadline
        Issue.record("\(screen): not drawn in \(timeout) s: \(why)")
    }

    /// The picture, as the platform's device calls it (`phone`, or on its
    /// side `phone-landscape`: HeadlessApp.picture's).
    private func shoot(_ app: HeadlessApp, _ screen: String) throws {
        let start = ContinuousClock.now
        let tries = try app.steadyPicture(screen)
        print("[proof] \(screen): \(tries) pictures in \(ContinuousClock.now - start)")
    }
}

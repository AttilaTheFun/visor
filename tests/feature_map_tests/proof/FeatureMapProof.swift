// The release's proof, through Isomer's driver: the fixture's screens a
// release is compared by (tools/ci/proof_ios.sh's SCREENS, snapshots.py's
// for Android, proof_mac.sh's), each pictured by the platform's launcher
// (HeadlessApp.picture: `ios/phone/chat`, `ios/phone-landscape/chat`,
// `android/phone/chat`, `macos/window/chat`). One launch of the fixture
// walks FEATURE_MAP.md's edges to every screen it reaches (Sessions, Add
// Computer and its MultiPass sign-in, New Session, a chat, its details,
// the goal's chat); a screen whose fixture's data differs (the question
// waiting, the computers' machines, a Runner's accounts, the earlier rows)
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

    /// How a screen is told once its own launch has opened it.
    static func node(_ screen: String) -> FeatureMapNode? {
        switch screen {
        case "onboarding": .onboarding
        case "sessions", "machines", "runner-accounts": .sessions
        case "chat", "goal", "earlier", "commands": .chat
        case "question": .question
        case "inspector": .details
        case "models": .model
        case "search": .search
        case "connect": .addComputer
        case "runner": .runner
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
        let reached = ["sessions", "connect", "runner", "new-session", "chat", "inspector", "goal"]
        guard !wanted.isDisjoint(with: reached) else { return }
        // The iPhone's app on its side turns itself on an upright simulator
        // (fixture.orientation), where Isomer's Apple driver's taps on a
        // list's rows don't take (IsomerGap.appleLandscapeTap): each screen
        // a launch of its own there.
        guard Self.settings["fixture.orientation"] != "landscape" else { return }
        let app = try VisorLaunch.fixture("sessions", settings: Self.settings)
        defer { app.quit() }
        func take(_ screen: String) throws {
            guard wanted.contains(screen) else { return }
            try shoot(app, screen)
            taken.insert(screen)
        }
        try arrive(app, at: "sessions")
        try take("sessions")

        // Sessions → Add Computer → Sign in to a MultiPass; put away. Where
        // the tap doesn't take (IsomerGap.appleLandscapeTap), both are
        // launches of their own, and the walk goes on from Sessions.
        if wanted.contains("connect") || wanted.contains("runner") {
            var opened = true
            do {
                try app.tap(id: "add-computer", else: "Add Computer…")
            } catch {
                opened = false
                withKnownIssue(Comment(rawValue: IsomerGap.appleLandscapeTap.rawValue)) {
                    Issue.record(error, "Add Computer: a launch of its own")
                }
            }
            if opened {
                try arrive(app, at: "connect")
                try take("connect")
                if wanted.contains("runner") {
                    try app.tap(id: "runner", else: "Sign In to a MultiPass…")
                    try arrive(app, at: "runner")
                    try take("runner")
                }
                try app.putAway()
                try arrive(app, at: "sessions")
            }
        }

        // Sessions → New Session (the bottom bar's compose); put away.
        if wanted.contains("new-session") {
            let compose = try app.screen().element("New session") != nil ? "New session" : "✎"
            try app.tap(compose)
            try arrive(app, at: "new-session")
            try take("new-session")
            try app.putAway()
            try arrive(app, at: "sessions")
        }

        // Sessions → the chat → its details, and back to Sessions.
        if wanted.contains("chat") || wanted.contains("inspector") {
            try app.tap(id: "session-fixture-chat", else: "Offline sync", .listRow)
            try arrive(app, at: "chat")
            try take("chat")
            if wanted.contains("inspector") {
                try app.tap(id: "session-title", else: "Session details")
                try arrive(app, at: "inspector")
                try take("inspector")
                try app.tap(id: "details-done", else: "Done")
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
            try app.tap(id: "session-fixture-docs", else: "Release notes", .listRow)
            try arrive(app, at: "goal")
            try take("goal")
        }
    }

    /// Waits for `screen`'s node (when it has one), recording an issue if it
    /// never shows; its picture is taken all the same.
    private func arrive(_ app: HeadlessApp, at screen: String, timeout: Double = 15) throws {
        guard let node = Self.node(screen) else {
            Thread.sleep(forTimeInterval: 4)
            return
        }
        // The commands' chat: its slash commands offered, over it on the
        // iPhone (a popover, all the driver lists while it's open).
        let isShown = { (shown: HeadlessScreen) in
            node.isShown(on: shown) || (screen == "commands" && shown.elements.contains { $0.label.hasPrefix("/goal") })
        }
        let start = ContinuousClock.now
        let shown = try app.screen(within: timeout) { isShown($0) }
        #expect(isShown(shown), "\(screen): not \(node.rawValue): \(shown.summary)")
        print("[proof] \(screen): there in \(ContinuousClock.now - start)")
    }

    /// The picture, as the platform's device calls it: Android's on its
    /// side is `phone-landscape`, as the proof's ids have it (Isomer's
    /// `picture` calls every Android picture `phone`).
    private func shoot(_ app: HeadlessApp, _ screen: String) throws {
        let info = try app.info()
        let device: String? = info.platform.lowercased() == "android" && info.width > info.height ? "phone-landscape" : nil
        let start = ContinuousClock.now
        let tries = try app.steadyPicture(screen, device: device)
        print("[proof] \(screen): \(tries) pictures in \(ContinuousClock.now - start)")
    }
}

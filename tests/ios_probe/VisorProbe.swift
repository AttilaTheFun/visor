import UIKit
import XCTest

/// Drives the phone client in the simulator, for looking at it and for
/// recording it: a send (for the send-motion check), the composer, the
/// archive list, and the snapshot fixture's screens. On the main actor,
/// where XCUIApplication is.
@MainActor
final class VisorProbe: XCTestCase {
    private let outDir = "/private/tmp/visor_probe"

    /// The orientation a run's behaviour cases are held in:
    /// VISOR_PROBE_ORIENTATION=landscape turns them all on their side
    /// (`--test_env`), portrait otherwise. The screens' pictures say their
    /// own (testFixtureScreens, testFixtureScreensLandscape, testSiteShots).
    nonisolated static var runOrientation: UIDeviceOrientation {
        ProcessInfo.processInfo.environment["VISOR_PROBE_ORIENTATION"] == "landscape" ? .landscapeLeft : .portrait
    }

    /// Every case starts in the run's orientation, whichever way the phone
    /// lies (the lab's iPhone stands on its side).
    override nonisolated func setUp() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = Self.runOrientation }
    }

    /// Every case leaves the device upright: a simulator left on its side
    /// gave the next tests on it (another app's snapshot tests, too) a
    /// landscape phone's insets.
    override nonisolated func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
    }

    /// The send, as a person does it, for a screen recording to be taken
    /// of: the session named by VISOR_FRAMES_SESSION is opened, the
    /// composer tapped (the on-screen keyboard comes up), a message typed
    /// and sent, and the reply waited for. Marks go to the log with times.
    func testSendFrames() throws {
        let env = ProcessInfo.processInfo.environment
        let id = env["VISOR_FRAMES_SESSION"] ?? ""
        XCTAssertFalse(id.isEmpty, "VISOR_FRAMES_SESSION is required")
        let app = XCUIApplication()
        // A fresh simulator's first launch asks about notifications: the
        // question is answered, not left over the composer.
        addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for name in ["Allow", "Open"] where alert.buttons[name].exists {
                alert.buttons[name].tap()
                return true
            }
            return false
        }
        app.launch()
        // An interaction, for the monitor to answer the question: on the
        // status bar, since the middle of a long list is a session's row.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        let row = app.descendants(matching: .any).matching(identifier: "session-" + id).firstMatch
        if !row.waitForExistence(timeout: 15) {
            // No computer yet (an erased simulator): add the host by its
            // address and password, as testSelectSession does.
            let add = app.buttons["add-computer"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "no session row and no Add Computer row")
            add.tap()
            let host = app.textFields["host"].firstMatch
            XCTAssertTrue(host.waitForExistence(timeout: 10), "no connect form")
            host.tap()
            if let code = env["VISOR_PROBE_CODE"], !code.isEmpty {
                // The connection code, which carries the address and the
                // password: typed, since a URL typed into the simulator
                // loses the second slash of its "//" (http:/…), however
                // it is typed.
                host.typeText(code)
            } else {
                host.typeText(env["VISOR_PROBE_HOST"] ?? "my-mac.example.ts.net")
                let secure = app.secureTextFields["password"].firstMatch
                if secure.waitForExistence(timeout: 5) { secure.tap(); secure.typeText(env["VISOR_PROBE_PASSWORD"] ?? "") }
            }
            app.buttons["connect"].firstMatch.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the session's row did not appear")
        row.tap()
        let composer = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "no composer")
        Thread.sleep(forTimeInterval: 3)
        if env["VISOR_FRAMES_RELAUNCH"] == "1" {
            // The thread seen once and kept; then the app launched afresh
            // (an update, or iOS ending it while away) and the session
            // opened from what was kept.
            app.terminate()
            app.launch()
            NSLog("VISOR_FRAMES relaunched")
            XCTAssertTrue(row.waitForExistence(timeout: 30), "the session's row did not appear again")
            row.tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 15), "no composer again")
            Thread.sleep(forTimeInterval: 3)
        }
        NSLog("VISOR_FRAMES tap-composer")
        composer.tap()
        Thread.sleep(forTimeInterval: 2)
        NSLog("VISOR_FRAMES type")
        composer.typeText(env["VISOR_FRAMES_TEXT"] ?? "Reply with exactly the word banana")
        Thread.sleep(forTimeInterval: 1)
        if env["VISOR_FRAMES_READ"] == "1" {
            // Up the thread, keyboard and all, as when reading a long reply
            // from its start before sending: the message is sent from there.
            for _ in 0..<2 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            }
            Thread.sleep(forTimeInterval: 1.5)
            NSLog("VISOR_FRAMES read")
        }
        if let away = env["VISOR_FRAMES_AWAY"].flatMap(Double.init), away > 0 {
            // Away and back, the message typed, and sent the moment the
            // app is in front again: while it opens its channels afresh.
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: away)
            NSLog("VISOR_FRAMES back")
            app.activate()
            Thread.sleep(forTimeInterval: 0.3)
        }
        NSLog("VISOR_FRAMES send")
        app.buttons["Send"].firstMatch.tap()
        if env["VISOR_FRAMES_SCROLL"] == "1" {
            // Away from the status row and back while the agent works.
            Thread.sleep(forTimeInterval: 4)
            let thread = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
            NSLog("VISOR_FRAMES scroll-away")
            thread.swipeDown(velocity: .fast)
            thread.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 2)
            NSLog("VISOR_FRAMES scroll-back")
            thread.swipeUp(velocity: .fast)
            thread.swipeUp(velocity: .fast)
            thread.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 3)
            NSLog("VISOR_FRAMES back")
        }
        Thread.sleep(forTimeInterval: 20)
        // To the background, where the app keeps its connection log.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        NSLog("VISOR_FRAMES end")
    }

    /// Swiping an archived session part-way, and holding it there, as a
    /// person does before deciding: the session named by
    /// VISOR_SWIPE_SESSION must be archived on the computer. Three slow
    /// swipes, each held, so a profiler watching the app sees the moment
    /// the actions first appear.
    func testArchivedSwipe() throws {
        let env = ProcessInfo.processInfo.environment
        let id = env["VISOR_SWIPE_SESSION"] ?? ""
        XCTAssertFalse(id.isEmpty, "VISOR_SWIPE_SESSION is required")
        let app = XCUIApplication()
        app.launch()
        let archive = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'archived-'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 30), "no Archived row")
        archive.tap()
        let row = app.descendants(matching: .any).matching(identifier: "archived-session-" + id).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the archived session is not listed")
        Thread.sleep(forTimeInterval: 2)
        NSLog("VISOR_SWIPE begin")
        for _ in 0..<3 {
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.5)
            Thread.sleep(forTimeInterval: 1.5)
        }
        NSLog("VISOR_SWIPE end")
        shot(app, "swipe-1")
    }

    /// Tapping a session in the sidebar opens it: the row for the session
    /// named by VISOR_SELECT_SESSION (its id) is tapped, and the chat's
    /// composer must appear.
    func testSelectSession() throws {
        let env = ProcessInfo.processInfo.environment
        let id = env["VISOR_SELECT_SESSION"] ?? ""
        XCTAssertFalse(id.isEmpty, "VISOR_SELECT_SESSION is required")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "alerts") { alert in
            for name in ["Allow", "Open"] where alert.buttons[name].exists {
                alert.buttons[name].tap()
                return true
            }
            return false
        }
        app.launch()
        // An interaction, for the monitor to answer the question: on the
        // status bar, since the middle of a long list is a session's row.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        let row = app.descendants(matching: .any).matching(identifier: "session-" + id).firstMatch
        if !row.waitForExistence(timeout: 15) {
            // No computer yet: add the host — by its connection code
            // (VISOR_PROBE_CODE), else by its address and password.
            let add = app.buttons["add-computer"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add Computer row")
            add.tap()
            let host = app.textFields["host"].firstMatch
            XCTAssertTrue(host.waitForExistence(timeout: 10), "no connect form")
            host.tap()
            if let code = env["VISOR_PROBE_CODE"], !code.isEmpty {
                host.typeText(code)
            } else {
                host.typeText(env["VISOR_PROBE_HOST"] ?? "my-mac.example.ts.net")
                let secure = app.secureTextFields["password"].firstMatch
                if secure.waitForExistence(timeout: 5) { secure.tap(); secure.typeText(env["VISOR_PROBE_PASSWORD"] ?? "") }
            }
            app.buttons["connect"].firstMatch.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the session's row did not appear")
        shot(app, "select-1-sidebar")
        // The moment the session is opened, for a recording of it.
        Thread.sleep(forTimeInterval: 2)
        NSLog("VISOR_SELECT tap")
        row.tap()
        let composer = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "tapping the session did not open it")
        shot(app, "select-2-opened")
        // Long enough for the first sync to answer and the thread to settle.
        Thread.sleep(forTimeInterval: 8)
        NSLog("VISOR_SELECT end")
    }

    /// A message shows the instant it is sent, marked Sending, above the
    /// reply, and settles into the transcript without moving. The session
    /// is a throwaway named by VISOR_LOOK_SESSION.
    func testSendLook() throws {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let env = ProcessInfo.processInfo.environment
        let add = app.buttons["add-computer"].firstMatch
        if add.waitForExistence(timeout: 10) { add.tap() }
        let host = app.textFields["host"].firstMatch
        if host.waitForExistence(timeout: 20) {
            host.tap(); host.typeText(env["VISOR_PROBE_HOST"] ?? "my-mac.example.ts.net")
            let secure = app.secureTextFields["password"].firstMatch
            if secure.waitForExistence(timeout: 5) { secure.tap(); secure.typeText(env["VISOR_PROBE_PASSWORD"] ?? "") }
            app.buttons["connect"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 8)
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.tap() }
            Thread.sleep(forTimeInterval: 4)
        }
        let wanted = env["VISOR_LOOK_SESSION"] ?? "send-look"
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS %@", wanted)).firstMatch
        if row.waitForExistence(timeout: 20) { row.tap() } else {
            let any = app.staticTexts[wanted].firstMatch
            XCTAssertTrue(any.waitForExistence(timeout: 20), "no session row to open"); any.tap()
        }
        Thread.sleep(forTimeInterval: 5)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer")
        field.tap()
        field.typeText("Reply with exactly: PONG")
        app.buttons["Send"].firstMatch.tap()
        // Right away: the message should be on screen, marked Sending.
        Thread.sleep(forTimeInterval: 1)
        shot(app, "send-1-immediately")
        // While that reply runs, a second message: it should queue BELOW
        // the reply, not jump above it.
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        composer.tap()
        composer.typeText("Count slowly to 30, one line each")
        app.buttons["Send"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        let again = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        if again.waitForExistence(timeout: 3) { again.tap(); again.typeText("A follow-up while busy") ; app.buttons["Send"].firstMatch.tap() }
        Thread.sleep(forTimeInterval: 2)
        shot(app, "send-2-queued-below")
        Thread.sleep(forTimeInterval: 20)
        // Settled: everything in send order, no duplicate.
        shot(app, "send-3-settled")
    }

    /// Every fixture screen (VisorFixture), each from a fresh launch with
    /// the canned computer: the same pixels every run is the point.
    func testFixtureScreens() throws {
        fixtureShots(.portrait)
    }

    /// The same screens in landscape, turned so on purpose.
    func testFixtureScreensLandscape() throws {
        fixtureShots(.landscapeLeft)
    }

    private func fixtureShots(_ orientation: UIDeviceOrientation) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = orientation
        for screen in ["sessions", "chat", "question", "goal", "inspector", "models", "search", "connect", "new-session"] {
            let app = XCUIApplication()
            app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", screen]
            app.launch()
            // Turned again once the app is up: one launched while the
            // phone already lies on its side can come up in portrait.
            if orientation != .portrait {
                XCUIDevice.shared.orientation = .portrait
                XCUIDevice.shared.orientation = orientation
            }
            // The search's matches in messages come a moment after its
            // sessions: waited for, or the picture had them only some runs.
            if screen == "search" {
                XCTAssertTrue(app.staticTexts["Messages"].waitForExistence(timeout: 15), "the search found no messages")
            }
            Thread.sleep(forTimeInterval: 4)
            shot(app, "fixture-" + screen)
            app.terminate()
        }
    }

    /// Learning that there are rows before the thread's moves nothing in
    /// it: the fixture's chat opens with none known, and ten seconds on its
    /// sync says there are some, as a server's first answer after a launch
    /// can. The row standing for them is put in at the top when that
    /// happens if it is not there already, and every row under it moved
    /// down: the thread jumped on the first send after a launch (Visor 0.26).
    func testLearningOfEarlierRowsMovesNothing() throws {
        XCUIDevice.shared.orientation = Self.runOrientation
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "learns-earlier"]
        app.launch()
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Rows now sync in the background, and the banner'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5), "the chat's last row did not appear")
        // Settled on its last row; the word of earlier rows not yet come.
        Thread.sleep(forTimeInterval: 1)
        let before = last.frame
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(last.exists, "the thread moved its last row out of view when it learned of earlier rows")
        XCTAssertEqual(last.frame.minY, before.minY, accuracy: 0.5, "the thread moved when it learned of earlier rows")
        shot(app, "earlier-rows-learned")
        app.terminate()
    }

    /// Rows coming in while the thread is read further up move nothing in
    /// it: the fixture's chat, scrolled up, gets two rows twelve seconds on
    /// and one more fourteen seconds after. What was read stays where it was,
    /// a pill says how many came in below and goes a few seconds later, and
    /// its tap takes the thread down to the newest.
    func testRowsArrivingWhileReadingAboveMoveNothing() throws {
        XCUIDevice.shared.orientation = Self.runOrientation
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "arrivals"]
        app.launch()
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Rows now sync in the background, and the banner'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 8), "the chat's last row did not appear")
        Thread.sleep(forTimeInterval: 1)
        // Up the thread, as when reading: its end out of view.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        Thread.sleep(forTimeInterval: 1.5)
        // A row in view to watch: the first of these that can be seen —
        // plain text rows, whose frame is read at once (a /goal card's took
        // up to 10 s on CI, and the pill, which stays 4 s, was gone).
        let read = ["layout I want for the offline banner", "the sync notes", "Found it."]
            .lazy.map { app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch }
            .first { $0.exists && $0.isHittable }
        let watched = try XCTUnwrap(read, "no row in view after scrolling up")
        let before = watched.frame
        let pill = app.buttons["new-rows-pill"]
        // Waited for with its count: on a slow machine the pill can show
        // the first of the two rows for a moment before the second. In the
        // fixture the pill stays until tapped (`newRowsPillSeconds`).
        let two = app.buttons.matching(NSPredicate(format: "identifier == 'new-rows-pill' AND label CONTAINS '2 new messages'")).firstMatch
        XCTAssertTrue(two.waitForExistence(timeout: 20), "no pill for the two rows that came in below")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        shot(app, "arrivals-pill")
        XCTAssertEqual(watched.frame.minY, before.minY, accuracy: 0.5, "what was read moved when rows came in below")
        // The third row: counted on the same pill, and its tap goes down to it.
        let three = app.buttons.matching(NSPredicate(format: "identifier == 'new-rows-pill' AND label CONTAINS '3 new messages'")).firstMatch
        XCTAssertTrue(three.waitForExistence(timeout: 24), "the third row is not counted")
        XCTAssertEqual(watched.frame.minY, before.minY, accuracy: 0.5, "what was read moved when the third row came in")
        pill.tap()
        let newest = app.staticTexts["All 42 sync tests pass, offline rows included."]
        XCTAssertTrue(newest.waitForExistence(timeout: 3), "the newest row is not in the thread")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(newest.isHittable, "the pill's tap did not take the thread down to the newest row")
        XCTAssertFalse(pill.exists, "the pill stayed after its tap")
        app.terminate()
    }

    /// Rows coming in while the thread is at its end are scrolled to, and
    /// there is no pill.
    func testRowsArrivingAtTheEndAreScrolledTo() throws {
        XCUIDevice.shared.orientation = Self.runOrientation
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "arrivals"]
        app.launch()
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Rows now sync in the background, and the banner'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 8), "the chat's last row did not appear")
        let arrived = app.staticTexts["Running the sync tests now."]
        XCTAssertTrue(arrived.waitForExistence(timeout: 20), "the rows that came in are not in the thread")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(arrived.isHittable, "the thread did not go down to the rows that came in")
        XCTAssertFalse(app.buttons["new-rows-pill"].exists, "a pill while at the end")
        shot(app, "arrivals-at-the-end")
        app.terminate()
    }

    /// A burst of long rows at the end, more than a screen of them in one
    /// change (a reply that ran on while the app was away), is followed
    /// to its end: the list scrolls before it has measured them, and the
    /// rows it measures afterwards must not leave the thread short of its
    /// end (the "half a page back" Logan saw on coming back to a session).
    func testABurstOfRowsAtTheEndIsFollowedToItsEnd() throws {
        XCUIDevice.shared.orientation = Self.runOrientation
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "burst"]
        app.launch()
        let done = app.staticTexts["Burst done: every row is on the server."]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the burst did not come")
        Thread.sleep(forTimeInterval: 3)
        shot(app, "burst-followed")
        XCTAssertTrue(done.isHittable, "the thread stopped short of the burst's end")
        XCTAssertFalse(app.buttons["new-rows-pill"].exists, "a pill while following the end")
        app.terminate()
    }

    /// Typing through an autocorrection: what is typed after a word the
    /// keyboard lengthened ("dont" to "don't") goes after it. The field says
    /// where its caret is a moment after the words change, and the caret
    /// from the words before, handed back to it in that moment, moved it a
    /// letter back: "I don't kno whatw" (Logan: "weird jumps in the text
    /// insertion point when typing").
    func testTypingThroughAnAutocorrectionKeepsTheCaret() throws {
        XCUIDevice.shared.orientation = Self.runOrientation
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "chat"]
        app.launch()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer")
        field.tap()
        // Key by key, as a person types: `typeText` goes round the keyboard's
        // autocorrection.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "no on-screen keyboard (a hardware keyboard is connected?)")
        func type(_ text: String) {
            for character in text {
                let key = character == " " ? keyboard.keys["space"] : keyboard.keys[String(character)]
                if key.exists { key.tap() } else { field.typeText(String(character)) }
            }
        }
        // Corrections that lengthen the word ("dont" to "don't"): a caret
        // kept from the words before it is a letter short of the end.
        type("im sure i dont know ")
        type("what")
        Thread.sleep(forTimeInterval: 1)
        let typed = (field.value as? String ?? "").replacingOccurrences(of: "\u{2019}", with: "'")
        shot(app, "autocorrection-typed")
        XCTAssertTrue(typed.contains("don't"), "the keyboard did not correct dont, so this ran no correction: \(typed)")
        // What came after the corrected words, after them, in order.
        XCTAssertTrue(typed.lowercased().hasSuffix("sure i don't know what"), "what was typed after a correction went elsewhere: \(typed)")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count + 2))
        app.terminate()
    }

    /// Refusing dictation leaves the app running: the system's answer to
    /// the speech recognition prompt comes on a queue of its own, and a
    /// handler for it built on the main actor trapped there (0.29). Needs
    /// the prompt undecided (tools/ios_ui_tests.sh resets the simulator's
    /// permissions first; CI's simulator is new each run).
    func testRefusingDictationLeavesTheAppRunning() throws {
        XCUIDevice.shared.orientation = Self.runOrientation
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "chat"]
        app.launch()
        let mic = app.buttons["dictate"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone in the composer")
        mic.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let refuse = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        XCTAssertTrue(refuse.waitForExistence(timeout: 10), "no permission prompt: reset the simulator's permissions first")
        refuse.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "the app ended when dictation was refused")
        XCTAssertTrue(mic.exists, "the composer is gone after dictation was refused")
        shot(app, "dictation-refused")
        app.terminate()
    }

    /// The fixture's chat as drawn — a long bullet that starts in bold
    /// wraps rather than stopping at "…" — and the send button taking a
    /// tap beside its circle, in the room around it, not only on it.
    func testFixtureChatTouch() throws {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "chat"]
        app.launch()
        Thread.sleep(forTimeInterval: 4)
        // The long bullet is in the assistant's first reply, above.
        app.swipeDown()
        Thread.sleep(forTimeInterval: 1)
        shot(app, "chat-bullets")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer")
        field.tap()
        field.typeText("hit area check")
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send button")
        // Beside the drawn circle, down and to the right of it: 24 points
        // from its centre each way is 6 points past its edge.
        let frame = send.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX + 24, dy: frame.midY + 24)).tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot(app, "chat-after-tap-beside-send")
        let left = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertFalse((left.value as? String ?? "").contains("hit area check"), "a tap beside the send button sent the message")
    }

    /// Text in the thread can be selected: held down on, the agent's words
    /// (markdown) and the user's (plain text) each get a selection and the
    /// edit menu with Copy. A `safeAreaBar` on the thread's scroll view
    /// took the press on iOS 26 and 27, so nothing could be selected
    /// (AgentUI's composer is a safe-area inset for that).
    func testFixtureSelectText() throws {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "chat"]
        app.launch()
        Thread.sleep(forTimeInterval: 4)
        var offered: [String: Bool] = [:]
        for (label, name) in [("Rows now sync", "agent"), ("Here's the layout", "user")] {
            let words = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            XCTAssertTrue(words.waitForExistence(timeout: 10), "no \(name) message")
            words.press(forDuration: 1.2)
            Thread.sleep(forTimeInterval: 1)
            shot(app, "chat-select-text-\(name)")
            // The edit menu's Copy: a menu item before iOS 26, a button in
            // its glass bar since (not the message's own Copy button).
            let menuCopy = app.buttons.matching(NSPredicate(format: "label == 'Copy' AND identifier != 'copy-message'")).firstMatch
            offered[name] = app.menuItems["Copy"].firstMatch.waitForExistence(timeout: 3) || menuCopy.exists
            print("VISOR_SELECT \(name): Copy offered \(offered[name] ?? false)")
            // Away from the menu, to dismiss it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(offered, ["agent": true, "user": true], "where the edit menu offered Copy")
    }

    /// What a row opens over its thread, in the fixture's chat: the run of
    /// tool calls, and a picture. Each opens from a row, shows what it
    /// should, and goes with Done.
    func testFixtureSheets() throws {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "chat"]
        app.launch()
        let calls = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Made '")).firstMatch
        XCTAssertTrue(calls.waitForExistence(timeout: 10), "no run of tool calls in the thread")
        calls.tap()
        XCTAssertTrue(app.navigationBars["Tool calls"].waitForExistence(timeout: 5), "the tool calls did not open")
        shot(app, "sheet-1-calls")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Tool calls"].waitForNonExistence(timeout: 5), "the tool calls did not close")

        // The picture (the message carries a video too), opened in the
        // system's preview, which has its own Done.
        let picture = app.descendants(matching: .any).matching(identifier: "attachment-layout.png").firstMatch
        if !picture.isHittable { app.swipeDown() }
        XCTAssertTrue(picture.waitForExistence(timeout: 5), "no picture in the thread")
        picture.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8), "the picture did not open")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "sheet-2-picture")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "the picture did not close")
        app.terminate()
    }

    /// A slash typed in the fixture's chat offers the agent's commands,
    /// which the connection asked for when the session was opened.
    func testFixtureSlashCommands() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "chat"]
        app.launch()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer")
        field.tap()
        field.typeText("/comp")
        XCTAssertTrue(app.staticTexts["/compact"].waitForExistence(timeout: 5), "the commands were not offered")
        // Picked, the command is the draft, and the caret is after it:
        // what is typed next follows the command ("/compact x", not
        // "/comx pact").
        app.staticTexts["/compact"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        field.typeText("x")
        XCTAssertEqual(field.value as? String, "/compact x")
        shot(app, "slash-command-picked")
        // Cleared, as a person would. (The fixture keeps no drafts between
        // launches, so the cases after this one open an empty composer,
        // with its microphone, whatever happens here.)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "/compact x".count))
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    /// The agent's question (AskUserQuestion) opens as a sheet on its own:
    /// Send waits for an answer, an option picked is one, and sending
    /// closes the sheet; the composer keeps the question with Answer.
    func testFixtureQuestion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", "question"]
        app.launch()
        let send = app.buttons["question-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "the question did not open")
        XCTAssertTrue(app.staticTexts["Which way should rows written offline go to the server?"].exists)
        XCTAssertFalse(send.isEnabled, "Send before an answer")
        app.buttons["approval-On reconnect"].tap()
        XCTAssertTrue(send.isEnabled, "an option picked is an answer")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        shot(app, "question")
        send.tap()
        XCTAssertTrue(send.waitForNonExistence(timeout: 5), "the sheet stayed")
        XCTAssertTrue(app.buttons["answer"].waitForExistence(timeout: 5), "the composer does not keep the question")
        app.terminate()
    }

    /// The site's pictures of the phone (.github/workflows/screenshots.yml):
    /// the screenshot fixture's screens in the dark look, saved beside the
    /// probe's other pictures as `site-<screen>.png`.
    func testSiteShots() throws {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        for screen in ["sessions", "chat", "question", "models", "inspector"] {
            let app = XCUIApplication()
            app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", screen == "sessions" ? "" : screen,
                                   "-visor.fixture.appearance", "dark"]
            app.launch()
            Thread.sleep(forTimeInterval: 5)
            shot(app, "site-\(screen)")
            app.terminate()
        }
    }

    /// Looks, and sends nothing: opens a session the phone already lists
    /// and photographs the chat, the composer with the keyboard up, and
    /// (by its environment) a search, the attach menu, a picture or what
    /// the composer offers for words typed.
    func testComposerLook() throws {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        // A fresh install has no computer saved, and seeding the defaults
        // from outside does not survive cfprefsd. Type it in, as a person
        // would; this connects and starts nothing.
        // Connecting lives behind the Computers sheet now, which opens
        // itself when nothing is saved.
        // A plain-styled button in a list is a cell, not a button, so it
        // is found by the words on it.
        let add = app.buttons["add-computer"].firstMatch
        if add.waitForExistence(timeout: 10) {
            add.tap()
        } else {
            let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Add Computer")).firstMatch
            if row.waitForExistence(timeout: 10) { row.tap() }
        }
        Thread.sleep(forTimeInterval: 2)
        let host = app.textFields["host"].firstMatch
        if host.waitForExistence(timeout: 20) {
            let env = ProcessInfo.processInfo.environment
            host.tap()
            host.typeText(env["VISOR_PROBE_HOST"] ?? "my-mac.example.ts.net")
            let secure = app.secureTextFields["password"].firstMatch
            if secure.waitForExistence(timeout: 5) {
                secure.tap()
                secure.typeText(env["VISOR_PROBE_PASSWORD"] ?? "")
            }
            app.buttons["connect"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 8)
            // Out of the sheet the connect form sat in.
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.tap() }
            Thread.sleep(forTimeInterval: 4)
        }
        shot(app, "look-1-sidebar")
        // A search of the sidebar (VISOR_LOOK_SEARCH), and no further.
        if let words = ProcessInfo.processInfo.environment["VISOR_LOOK_SEARCH"], !words.isEmpty {
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")
            field.tap()
            field.typeText(words)
            Thread.sleep(forTimeInterval: 5)
            shot(app, "look-1-search")
            return
        }
        // A session row: the first cell that is not a computer or a folder.
        // A name no folder shares, or the folder row above it takes the tap.
        let wanted = ProcessInfo.processInfo.environment["VISOR_LOOK_SESSION"] ?? "Android Emulator on iOS"
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS %@", wanted)).firstMatch
        if row.waitForExistence(timeout: 20) {
            row.tap()
        } else {
            let any = app.staticTexts[wanted].firstMatch
            XCTAssertTrue(any.waitForExistence(timeout: 20), "no session row to open")
            any.tap()
        }
        // No assertion on the composer's kind: which element it is differs
        // by OS, and waiting for the wrong one hangs the run.
        Thread.sleep(forTimeInterval: 6)
        Thread.sleep(forTimeInterval: 4)
        shot(app, "look-2-chat")
        // The attach button's menu (VISOR_LOOK_ATTACH), and no further.
        if ProcessInfo.processInfo.environment["VISOR_LOOK_ATTACH"] != nil {
            let attach = app.buttons["attach"].firstMatch
            XCTAssertTrue(attach.waitForExistence(timeout: 10), "no attach button")
            attach.tap()
            Thread.sleep(forTimeInterval: 2)
            shot(app, "look-2-attach")
            let files = app.buttons["Files"].firstMatch
            if files.waitForExistence(timeout: 5) {
                files.tap()
                Thread.sleep(forTimeInterval: 3)
                shot(app, "look-2-files")
            }
            return
        }
        // A picture in the thread, opened (VISOR_LOOK_IMAGE), and no further.
        if ProcessInfo.processInfo.environment["VISOR_LOOK_IMAGE"] != nil {
            let picture = app.descendants(matching: .any).matching(identifier: "attachment-layout.png").firstMatch
            XCTAssertTrue(picture.waitForExistence(timeout: 10), "no picture in the thread")
            picture.tap()
            Thread.sleep(forTimeInterval: 4)
            shot(app, "look-2-image")
            return
        }
        // And with the keyboard up, where the composer moves to the edges.
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            Thread.sleep(forTimeInterval: 3)
            shot(app, "look-3-keyboard")
            // What the composer offers for words typed (VISOR_LOOK_TYPE,
            // e.g. "/co" for the slash commands); nothing is sent.
            if let typed = ProcessInfo.processInfo.environment["VISOR_LOOK_TYPE"], !typed.isEmpty {
                field.typeText(typed)
                Thread.sleep(forTimeInterval: 3)
                shot(app, "look-4-typed")
            }
        }
    }

    /// The screen now, as a picture: written to outDir (from the
    /// simulator, which shares this Mac's disk) and kept in the test's
    /// results too (how a phone's run brings its pictures back).
    private func shot(_ app: XCUIApplication, _ name: String) {
        // In landscape, the screen's picture: the app's comes out as its
        // portrait layout in half a landscape frame on iOS 27's simulator.
        let picture = (XCUIDevice.shared.orientation.isLandscape ? XCUIScreen.main.screenshot() : app.screenshot()).image
        // Drawn upright: the picture's orientation is a tag that not every
        // reader of the PNG applies.
        let format = UIGraphicsImageRendererFormat()
        format.scale = picture.scale
        // A phone's screen picture in landscape is its portrait frame with
        // the screen on its side: turned a quarter anticlockwise (the
        // runs turn it to landscapeLeft). The simulator's is landscape.
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

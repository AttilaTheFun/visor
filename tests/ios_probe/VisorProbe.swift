import XCTest

/// Drives the phone client in the simulator, for looking at it and for
/// recording it: a send (for the send-motion check), the composer, the
/// archive list, the terminal, and the snapshot fixture's screens. On the
/// main actor, where XCUIApplication is.
@MainActor
final class VisorProbe: XCTestCase {
    private let outDir = "/private/tmp/visor_probe"

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
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        for screen in ["sessions", "chat", "goal", "inspector", "models", "search", "connect"] {
            let app = XCUIApplication()
            app.launchArguments = ["-visor.fixture", "snapshot", "-visor.fixture.screen", screen]
            app.launch()
            Thread.sleep(forTimeInterval: 4)
            shot(app, "fixture-" + screen)
            app.terminate()
        }
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
        app.terminate()
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

    /// A terminal session from a phone, as the phone draws it: opened, the
    /// shell is drawn for this window at once; a line typed runs; the
    /// inspector says which window has it; and the sidebar afterwards. The
    /// session is a throwaway terminal session made over the API before
    /// the run (VISOR_LOOK_SESSION names it).
    func testTerminalLook() throws {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
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
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.tap() }
            Thread.sleep(forTimeInterval: 4)
        }
        let wanted = ProcessInfo.processInfo.environment["VISOR_LOOK_SESSION"] ?? "probe-terminal-look"
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS %@", wanted)).firstMatch
        if row.waitForExistence(timeout: 20) {
            row.tap()
        } else {
            let any = app.staticTexts[wanted].firstMatch
            XCTAssertTrue(any.waitForExistence(timeout: 20), "no session row to open")
            any.tap()
        }
        Thread.sleep(forTimeInterval: 6)
        shot(app, "term-0-terminal")
        // Typed into the shell: SwiftTerm takes the keyboard when tapped.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        app.typeText("echo visor-look-$((40 + 2)) cols=$COLUMNS -- 'q'\n")
        Thread.sleep(forTimeInterval: 3)
        shot(app, "term-1-typed")
        let title = app.buttons["session-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no title button")
        title.tap()
        Thread.sleep(forTimeInterval: 3)
        shot(app, "term-2-inspector")
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        Thread.sleep(forTimeInterval: 2)
        // And back to the sidebar: are the sessions still there?
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() } else { app.swipeRight() }
        Thread.sleep(forTimeInterval: 4)
        shot(app, "term-3-sidebar-after")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let data = app.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}

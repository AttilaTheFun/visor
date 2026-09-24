import XCTest

/// Drives the phone client against the menu bar app on this Mac: connect,
/// start a Claude Code session, read the reply, send a follow-up that runs
/// a shell command, and see its activity row.
final class VisorProbe: XCTestCase {
    private let outDir = "/private/tmp/visor_probe"

    func testClaudeSession() throws {
        let env = ProcessInfo.processInfo.environment
        let password = env["VISOR_PROBE_PASSWORD"] ?? ""
        let cwd = env["VISOR_PROBE_CWD"] ?? "~"
        // The Mac's tailnet name: clients always connect over TLS (Tailscale Serve).
        let hostName = env["VISOR_PROBE_HOST"] ?? "my-mac.example.ts.net"
        NSLog("VISOR_PROBE typing host=%@ (env %@)", hostName, env["VISOR_PROBE_HOST"] ?? "unset")
        // No password: the simulator shares this Mac's Tailscale, so the
        // computer lets it in as its owner's device.
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        // The sessions list's last row adds a computer.
        let addComputer = app.buttons["add-computer"].firstMatch
        XCTAssertTrue(addComputer.waitForExistence(timeout: 20), "no Add Computer row")
        addComputer.tap()
        let host = app.textFields["host"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 20), "connect form did not appear")
        host.tap()
        host.typeText(hostName)
        if !password.isEmpty {
            let secure = app.secureTextFields["password"].firstMatch
            secure.tap()
            secure.typeText(password)
        }
        shot(app, "1-connect")
        app.buttons["connect"].firstMatch.tap()

        // The computer's section shows once the host answered the login.
        // The computer's rows appear with the login's answer; the header's
        // symbol reads "Connected" once it is.
        let connected = app.images.matching(NSPredicate(format: "label == 'Connected'")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 30), "host did not connect")
        // New Project → the folder picker: type the folder's path, choose it.
        let newProject = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'New Project'")).firstMatch
        XCTAssertTrue(newProject.waitForExistence(timeout: 10), "no New Project row")
        shot(app, "2-sidebar")
        newProject.tap()
        let pathField = app.textFields["folder-path"].firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 10), "folder picker did not appear")
        pathField.tap()
        pathField.press(forDuration: 1.0)
        app.menuItems["Select All"].firstMatch.tap()
        pathField.typeText(cwd)
        shot(app, "3-folder-picker")
        app.buttons["choose-folder"].firstMatch.tap()

        // The project's header row appears with its compose button, and the
        // new session sheet opens on it.
        let projectName = (cwd as NSString).lastPathComponent
        let start = app.buttons["start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "new session sheet did not appear")
        shot(app, "3-new-session")
        start.tap()

        // The agent page opens empty; the first message goes in the composer.
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "composer missing")
        first.tap()
        first.typeText("Reply with exactly: hello there")
        app.buttons["Send"].firstMatch.tap()

        // The reply streams into the agent page.
        // The assistant's bubble is exactly the reply (the user's bubble contains it too).
        let reply = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'hello there'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "no reply from the agent")
        shot(app, "4-reply")

        // A follow-up that makes the agent run a command: its activity row names it.
        let composer = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer missing")
        composer.tap()
        composer.typeText("Run the shell command `echo visor-ok` and tell me its output.")
        app.buttons["Send"].firstMatch.tap()
        let activity = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Bash: echo visor-ok'")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 120), "the tool activity never showed")
        // The turn ends: Send is back (Stop is shown while busy).
        XCTAssertTrue(app.buttons["Send"].firstMatch.waitForExistence(timeout: 120), "the turn did not finish")
        app.swipeDown()
        sleep(1)
        shot(app, "5-follow-up")

        // Back to the sidebar: the session is listed under its project,
        // named after the agent.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        let project = app.staticTexts.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10), "project header missing in the sidebar")
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Claude Code'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "session row missing in the sidebar")
        shot(app, "6-sidebar-session")

        // Swipe to archive: the row leaves the section, the archive row appears.
        row.swipeLeft()
        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 5), "no Archive swipe action")
        archive.tap()
        // The archived session stays under its project, with the command
        // that resumes the agent's own session.
        let resume = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'claude --resume'")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "the archived session is not listed under its project")
        shot(app, "7-archived-row")
        let archivedRow = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Claude Code'")).firstMatch
        XCTAssertTrue(archivedRow.waitForExistence(timeout: 5), "the archived session lost its title")
        shot(app, "8-archive-list")
        archivedRow.swipeRight()
        let unarchive = app.buttons["Unarchive"].firstMatch
        XCTAssertTrue(unarchive.waitForExistence(timeout: 5), "no Unarchive swipe action")
        unarchive.tap()
        // Back in the section, resumable: a message gets a reply from the same session.
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the session did not return to the section")
        row.tap()
        let again = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        again.tap()
        again.typeText("Repeat your very first reply in this conversation, verbatim, nothing else.")
        app.buttons["Send"].firstMatch.tap()
        let recalled = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'hello there' AND NOT label CONTAINS 'exactly'")).element(boundBy: 1)
        XCTAssertTrue(recalled.waitForExistence(timeout: 120), "the resumed session did not recall its first reply")
        shot(app, "9-resumed")

        // Manual mode: a command that needs permission waits for Allow.
        app.buttons["Permissions"].firstMatch.tap()
        let manual = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Manual'")).firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 5), "no Manual option")
        manual.tap()
        sleep(3)
        let stamp = Int(Date().timeIntervalSince1970)
        again.tap()
        again.typeText("Run the shell command `touch /tmp/visor-probe-\(stamp)` and say whether it worked, in one line.")
        app.buttons["Send"].firstMatch.tap()
        let allow = app.buttons["allow"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 120), "no approval request appeared")
        shot(app, "10-approval")
        allow.tap()
        let worked = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'worked' AND NOT label BEGINSWITH 'Run'")).firstMatch
        XCTAssertTrue(worked.waitForExistence(timeout: 120), "no reply after allowing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/tmp/visor-probe-\(stamp)"), "the allowed command did not run")
        shot(app, "11-allowed")

        // Resume: a second session in the project picks the first one's Claude
        // session from the list and recalls it.
        if back.exists { back.tap() }
        let compose = app.buttons["compose-" + projectName].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "no compose button on the project")
        compose.tap()
        let resumeTab = app.buttons["Resume"].firstMatch
        XCTAssertTrue(resumeTab.waitForExistence(timeout: 10), "no Resume mode")
        resumeTab.tap()
        let candidate = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Reply with exactly'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 30), "the earlier session is not listed for resuming")
        candidate.tap()
        shot(app, "12-resume-picker")
        app.buttons["start"].firstMatch.tap()
        let composer2 = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(composer2.waitForExistence(timeout: 10))
        composer2.tap()
        composer2.typeText("What two words did you reply with first in this conversation? Just them.")
        app.buttons["Send"].firstMatch.tap()
        let resumed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'hello there' AND NOT label CONTAINS 'exactly'")).firstMatch
        XCTAssertTrue(resumed.waitForExistence(timeout: 120), "the resumed session did not recall the earlier conversation")
        shot(app, "13-resumed-session")
    }

    /// Looks, and touches nothing. Opens whatever session the phone
    /// already lists and photographs the chat, which is the only way to
    /// see the composer's own layout from here: the Mac refuses both
    /// screen recording and accessibility to this process.
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
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "session-" + id).firstMatch
        if !row.waitForExistence(timeout: 15) {
            // No computer yet: add the host by name (the simulator shares
            // this Mac's Tailscale identity, so no password).
            let add = app.buttons["add-computer"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add Computer row")
            add.tap()
            let host = app.textFields["host"].firstMatch
            XCTAssertTrue(host.waitForExistence(timeout: 10), "no connect form")
            host.tap(); host.typeText(env["VISOR_PROBE_HOST"] ?? "my-mac.example.ts.net")
            app.buttons["connect"].firstMatch.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the session's row did not appear")
        shot(app, "select-1-sidebar")
        row.tap()
        let composer = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "tapping the session did not open it")
        shot(app, "select-2-opened")
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
        // And with the keyboard up, where the composer moves to the edges.
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            Thread.sleep(forTimeInterval: 3)
            shot(app, "look-3-keyboard")
        }
    }

    /// Taking control of a session from a phone, as the phone draws it:
    /// the chat, the inspector, the confirmation, the terminal it becomes,
    /// and the sidebar afterwards. The session is a throwaway made over
    /// the API before the run (VISOR_LOOK_SESSION names it).
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
        Thread.sleep(forTimeInterval: 5)
        shot(app, "term-0-chat")
        let title = app.buttons["session-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no title button")
        title.tap()
        Thread.sleep(forTimeInterval: 3)
        shot(app, "term-1-inspector")
        let take = app.buttons["Take control of the terminal"].firstMatch
        XCTAssertTrue(take.waitForExistence(timeout: 5), "no take-control button")
        take.tap()
        Thread.sleep(forTimeInterval: 2)
        shot(app, "term-2-confirm")
        let confirm = app.alerts.buttons["Take control"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation")
        confirm.tap()
        Thread.sleep(forTimeInterval: 8)
        shot(app, "term-3-terminal")
        Thread.sleep(forTimeInterval: 6)
        shot(app, "term-4-terminal-later")
        // And back to the sidebar: are the sessions still there?
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() } else { app.swipeRight() }
        Thread.sleep(forTimeInterval: 4)
        shot(app, "term-5-sidebar-after")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let data = app.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}

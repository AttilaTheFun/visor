// What a computer's backups section says: each backup by when it was made
// and what it holds, and what a backup or a restore came to, naming each
// session it didn't do and why.

import VisorProtocol
@testable import VisorUI
import XCTest

@MainActor
final class BackupSectionTests: XCTestCase {
    private let backup = SessionBackup(path: "/Users/me/.local/share/visor/backups/20261103-013108", created: 1_000, from: "Mac", sessions: [
        SessionBackupItem(id: "a", title: "App", outcome: "Backed up.", kept: true),
        SessionBackupItem(id: "b", title: "New", outcome: "Not backed up: it has no conversation yet.", kept: false),
    ], size: 13 << 20)

    func testABackupIsNamedByWhenItWasMade() {
        XCTAssertEqual(BackupSection.name(of: backup), "20261103-013108")
        XCTAssertEqual(BackupSection.detail(of: backup, now: 1_000 + 7_200), "1 session, 13.0 MB, 2 hr ago")
    }

    func testWhatABackupAndARestoreCameTo() {
        XCTAssertEqual(BackupSection.summary(of: backup, restoring: false),
                       "Backed up 1 of 2 to /Users/me/.local/share/visor/backups/20261103-013108. New: Not backed up: it has no conversation yet.")
        var restored = backup
        restored.sessions = [SessionBackupItem(id: "a", title: "App", outcome: "Restored.", kept: true),
                             SessionBackupItem(id: "c", title: "Docs", outcome: "Here already: left as it is.", kept: true)]
        XCTAssertEqual(BackupSection.summary(of: restored, restoring: true), "Restored 1 of 2. Docs: Here already: left as it is.")
    }
}

// What a rolled-back update leaves behind: an update that did not stay up
// is undone by the platform's relauncher (the previous build put back and
// opened again), which writes a line here to say so. The server that comes
// back reads it once, says it in its menu and its log, and removes it.

import Foundation

extension VisorServer {
    /// Where the relauncher writes why an update was rolled back.
    public static var rollbackNoteURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("relaunch-rollback.txt", isDirectory: false)
    }

    /// The note, taken: shown as the update notice, logged, removed.
    func takeRollbackNote() {
        guard let note = try? String(contentsOf: Self.rollbackNoteURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: Self.rollbackNoteURL)
        let line = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        updateNotice = line
        Self.log(line)
    }
}

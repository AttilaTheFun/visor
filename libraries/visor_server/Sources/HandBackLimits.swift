// How much a handed-back session's conversation may bring
// (ReturnedConversationIntake): a move's caps (VisorServer+MigrationSize),
// so a runner returns no more than another server could send in a move.

import Foundation

package struct HandBackLimits: Equatable, Sendable {
    /// The most one file may be: a move's migrationFileCap.
    package var fileBytes: Int
    /// The most all of them may come to: a move's migrationTotalCap.
    package var totalBytes: Int
    /// The most files: as many as one archive of a move may unpack to.
    package var files: Int
    /// What is left free where they land, beyond them: a move's margin.
    package var freeMargin: Int

    package init(fileBytes: Int = VisorServer.migrationFileCap, totalBytes: Int = VisorServer.migrationTotalCap,
                 files: Int = VisorServer.unpackEntryCap, freeMargin: Int = VisorServer.migrationFreeMargin) {
        self.fileBytes = fileBytes
        self.totalBytes = totalBytes
        self.files = files
        self.freeMargin = freeMargin
    }
}

import Foundation
import VisorProtocol

/// A session moving here, as this server keeps the move until it ends:
/// what was offered, what this server said it would do, and where the
/// files carried for it are written.
struct IncomingMigration {
    var offer: MigrationOffer
    var plan: MigrationPlan
    var folder: URL
    var created: Date
}

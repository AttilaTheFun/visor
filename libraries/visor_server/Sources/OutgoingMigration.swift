import Foundation

/// A session offered for moving elsewhere, as the server it is on keeps
/// the offer: the files a client may read for it, by id, and where what was
/// packed for it is.
struct OutgoingMigration {
    var session: String
    var files: [String: URL]
    var folder: URL
    var created: Date
}

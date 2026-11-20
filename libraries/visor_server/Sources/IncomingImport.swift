import Foundation

/// A session archive being uploaded here to import (`POST /api/import`,
/// VisorServer+SessionArchive): where its pieces are written, how large
/// it said it is, and when it began.
struct IncomingImport {
    var file: URL
    var size: Int
    /// The file's own name, as the client had it.
    var name: String
    var folder: URL
    var created: Date
}

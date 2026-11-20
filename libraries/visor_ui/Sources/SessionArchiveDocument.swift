// An exported session archive, as SwiftUI's file exporter saves a document:
// the file read here (SessionExport), written where the person chooses.

import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct SessionArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.visorSession] }

    /// The archive, read from its computer into a file here.
    let url: URL

    init(url: URL) { self.url = url }

    /// Never opened as a document: an archive is imported (SessionImport).
    init(configuration: ReadConfiguration) throws { throw NotOpened() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: url) }

    private struct NotOpened: Error {}
}

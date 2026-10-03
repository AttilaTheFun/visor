#if os(iOS) || os(macOS)
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The connection log as a text file, for the share sheet: AirDrop and
/// Files take it as `visor-connection-log.txt`.
struct ConnectionLogFile: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { file in Data(file.text.utf8) }
            .suggestedFileName("visor-connection-log.txt")
    }
}
#endif

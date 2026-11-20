// A session archive imported into a computer's backups store
// (`POST /api/import`; docs/protocol.md, "Session archive v1"): this device
// reads the file it was given and uploads it a piece at a time, and the
// computer checks it as a move's files are checked and keeps it as a
// backed-up session, for the new-session sheet's Restore.

import Foundation
import Observation
import VisorProtocol

@MainActor
@Observable
public final class SessionImport: Identifiable {
    public enum Phase: Equatable {
        case importing
        /// Kept: the backup it is kept as.
        case done(SessionBackup)
        case failed(String)
    }

    public nonisolated let id: String
    public let file: URL
    public let host: AgentServerConnection
    public private(set) var phase: Phase = .importing
    /// How far the upload has come (0 to 1).
    public private(set) var progress = 0.0

    /// How much of the file is sent at a time.
    static let piece = 4 << 20

    public init(file: URL, host: AgentServerConnection) {
        id = host.id + "|" + file.path
        self.file = file
        self.host = host
    }

    /// The file uploaded and imported.
    public func run() async {
        phase = .importing
        progress = 0
        do {
            let size = ((try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw AgentServerError.message("\(file.lastPathComponent) is empty.") }
            let token = try await host.server.importUpload(size: size, name: file.lastPathComponent)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var offset = 0
            while offset < size {
                guard let data = try handle.read(upToCount: Self.piece), !data.isEmpty else {
                    throw AgentServerError.message("\(file.lastPathComponent) is shorter than it was.")
                }
                offset = try await host.server.importWrite(token, offset: offset, data: data.base64EncodedString())
                progress = Double(offset) / Double(size)
            }
            phase = .done(try await host.server.importFinish(token))
        } catch {
            phase = .failed(SessionExport.words(error))
        }
    }
}

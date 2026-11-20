// A session exported from its computer as a session archive
// (`<title>-<date>.visorsession`; docs/protocol.md, "Session archive v1"):
// the computer writes it, and this device reads it a piece at a time, as a
// move's file, into a file of its own for the person to save or share.

import Foundation
import Observation
import VisorProtocol

@MainActor
@Observable
public final class SessionExport: Identifiable {
    public enum Phase: Equatable {
        /// The computer writing it, then this device reading it.
        case exporting
        /// Read: the file, here.
        case ready(URL)
        case failed(String)
    }

    public nonisolated let id: String
    public let session: SessionInfo
    public let host: AgentServerConnection
    public private(set) var phase: Phase = .exporting
    /// How far the reading has come (0 to 1).
    public private(set) var progress = 0.0
    /// The archive's name and size, once the computer has written it.
    public private(set) var name = ""
    public private(set) var size = 0

    /// How much of the archive is read at a time.
    static let piece = 4 << 20

    public init(session: SessionInfo, host: AgentServerConnection) {
        id = host.id + "|" + session.id
        self.session = session
        self.host = host
    }

    /// The archive written and read here.
    public func run() async {
        phase = .exporting
        progress = 0
        do {
            let (token, file) = try await host.server.exportSession(session.id)
            name = file.place.isEmpty ? "Session.visorsession" : file.place
            size = file.size
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-export-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name, isDirectory: false)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw AgentServerError.message("Could not write \(url.path)")
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var offset = 0
            while offset < file.size {
                let read = try await host.server.migrationRead(token, file: file.id, offset: offset, length: Self.piece)
                guard let data = Data(base64Encoded: read.data), !data.isEmpty, read.next > offset else {
                    throw AgentServerError.message("The archive came short: \(offset) of \(file.size) bytes.")
                }
                try handle.write(contentsOf: data)
                offset = read.next
                progress = Double(offset) / Double(max(1, file.size))
            }
            phase = .ready(url)
        } catch {
            phase = .failed(Self.words(error))
        }
    }

    static func words(_ error: Error) -> String {
        if case AgentServerError.message(let text) = error { return text }
        if case AgentServerError.unsupported = error { return "This computer does not export sessions yet: update its Visor Server." }
        return "\(error)"
    }
}

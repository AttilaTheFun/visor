// A process's standard output and error, appended to its log file
// (Containerization's Writer): both streams to one writer, closed once.

import Containerization
import Foundation
import Synchronization

final class LogWriter: Writer {
    private let handle: Mutex<FileHandle?>

    init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let opened = try FileHandle(forWritingTo: url)
        try opened.seekToEnd()
        handle = Mutex(opened)
    }

    func write(_ data: Data) throws {
        try handle.withLock { try $0?.write(contentsOf: data) }
    }

    func close() throws {
        let closing = handle.withLock { held -> FileHandle? in
            defer { held = nil }
            return held
        }
        try closing?.close()
    }
}

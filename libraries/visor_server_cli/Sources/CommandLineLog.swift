import Foundation
import Synchronization

/// Where the server's lines go: the terminal, or a file, each line with
/// the time it was said.
final class CommandLineLog: Sendable {
    private let file: Mutex<FileHandle?>

    /// To `path`, appended to; the terminal when nil.
    init(path: String?) {
        guard let path else {
            file = Mutex(nil)
            return
        }
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
        file = Mutex(handle)
    }

    func write(_ line: String) {
        let stamped = Self.stamp.string(from: Date()) + "  " + line + "\n"
        file.withLock { handle in
            if let handle {
                try? handle.write(contentsOf: Data(stamped.utf8))
            } else {
                FileHandle.standardOutput.write(Data(stamped.utf8))
            }
        }
    }

    private static var stamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}

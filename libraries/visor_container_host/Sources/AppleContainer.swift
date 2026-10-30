import Foundation
import Synchronization

/// Apple's `container` (github.com/apple/container), run to its end: the
/// command-line tool every operation of visor-container-host is made of.
public struct AppleContainer: Sendable {
    /// The tool: where Apple's installer puts it, else Homebrew's, else the
    /// first on the PATH.
    public let tool: String

    public init(tool: String? = nil) {
        self.tool = tool ?? Self.locate() ?? "/usr/local/bin/container"
    }

    static func locate(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        let places = ["/usr/local/bin", "/opt/homebrew/bin"] + path.split(separator: ":").map(String.init)
        return places.map { $0 + "/container" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What a run said: its status, its standard output and its errors.
    struct Ran: Sendable {
        var status: Int32
        var output: String
        var errors: String

        /// Its words for a person: errors, else output.
        var said: String {
            let text = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
    }

    /// The tool run with `arguments`, `input` its standard input; nil when
    /// it couldn't be started.
    func run(_ arguments: [String], input: Data? = nil) -> Ran? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let feed = input.map { _ in Pipe() }
        process.standardInput = feed ?? FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        if let feed, let input {
            let writer = feed.fileHandleForWriting
            Thread.detachNewThread {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        // Read both to their end on threads of their own: either may fill.
        let errors = Collected()
        let reading = Thread { errors.add(err.fileHandleForReading.readDataToEndOfFile()) }
        reading.start()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while !errors.done { usleep(1000) }
        return Ran(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), errors: errors.text)
    }

    /// Rosetta is installed on this Mac: x86_64 Linux programs run in a
    /// container too (Android's build tools come for x86_64 alone).
    static var hasRosetta: Bool { FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") }
}

/// A pipe's bytes, read to their end on another thread.
private final class Collected: Sendable {
    private let read = Mutex<Data?>(nil)

    func add(_ chunk: Data) { read.withLock { $0 = chunk } }

    var done: Bool { read.withLock { $0 != nil } }

    var text: String { read.withLock { String(decoding: $0 ?? Data(), as: UTF8.self) } }
}

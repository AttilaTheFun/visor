import Foundation
import Synchronization

/// A program run to its end, as a container host and the Runner run theirs
/// (Apple's container, launchctl, a container host): its status, its output
/// and its errors.
public struct Tool: Sendable {
    /// The program: a path, or a name looked for on the PATH.
    public let program: String

    public init(_ program: String) { self.program = program }

    /// What a run said: its status, its standard output and its errors.
    public struct Ran: Sendable {
        public var status: Int32
        public var output: String
        public var errors: String

        /// Its words for a person: errors, else output.
        public var said: String {
            let text = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
    }

    /// The program run with `arguments`, `input` its standard input; nil
    /// when it couldn't be started.
    public func run(_ arguments: [String], input: Data? = nil) -> Ran? {
        let process = Process()
        if program.contains("/") {
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [program] + arguments
        }
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
}

/// A pipe's bytes, read to their end on another thread.
private final class Collected: Sendable {
    private let read = Mutex<Data?>(nil)

    func add(_ chunk: Data) { read.withLock { $0 = chunk } }

    var done: Bool { read.withLock { $0 != nil } }

    var text: String { read.withLock { String(decoding: $0 ?? Data(), as: UTF8.self) } }
}

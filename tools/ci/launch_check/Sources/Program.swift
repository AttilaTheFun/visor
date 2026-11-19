import Foundation

/// A program run to its end: its exit status and what it printed, its
/// standard output and error together.
struct Program {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }

    /// Runs `executable` with `arguments` and waits for it. Throws only
    /// when it can't be started.
    static func run(_ executable: String, _ arguments: [String]) throws -> Program {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw LaunchCheckError.setup("\(executable) couldn't be started: \(error.localizedDescription)")
        }
        // Read to the end before waiting, so a long output never fills the
        // pipe and stalls it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Program(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

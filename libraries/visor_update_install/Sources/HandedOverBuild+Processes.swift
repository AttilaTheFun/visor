import Dispatch
import Foundation

extension HandedOverBuild {
    /// The commands run as processes, each to its end on a queue of its own
    /// (cp of an app takes a few seconds), with what they write together.
    public static let processes: Run = { program, arguments in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ran(program, arguments))
            }
        }
    }

    /// A process run to its end, blocking.
    static func ran(_ program: String, _ arguments: [String]) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Outcome(status: -1, output: "\(program) couldn't be started: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

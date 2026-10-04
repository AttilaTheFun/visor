import Foundation

/// Runs `work`, which blocks (a program run to its end), on a thread of its
/// own rather than one of the threads Swift's tasks share.
func blocking<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: work()) }
    }
}

/// What a program prints, run to its end; nil when it could not be started
/// or did not succeed.
func output(of executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

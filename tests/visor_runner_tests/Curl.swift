import Foundation

/// `curl` with these arguments: what came back, and the HTTP status.
func curl(_ arguments: [String]) throws -> (body: String, status: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["-s", "-m", "10", "-w", "\n%{http_code}"] + arguments
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let lines = text.components(separatedBy: "\n")
    return (lines.dropLast().joined(separator: "\n"), lines.last ?? "")
}

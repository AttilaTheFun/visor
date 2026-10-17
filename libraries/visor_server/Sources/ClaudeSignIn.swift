// Signing Claude Code in again from a session (`/login`), for when its
// sign-in expired: `claude auth login` run beside the agent, with no
// terminal. It prints the page to sign in at, and reads back, a line at a
// time, the code that page shows ("<code>#<state>"); the user opens the
// page on whatever device they are on and sends the code from there.

import Foundation

@MainActor
final class ClaudeSignIn {
    /// The page to sign in at, once the command has said it.
    private(set) var url: String?
    /// Told the page, once; and how it ended: signed in, or why not.
    var onURL: (String) -> Void = { _ in }
    var onEnd: (_ signedIn: Bool, _ said: String) -> Void = { _, _ in }

    private let process = Process()
    private let input = Pipe()
    private var said = ""
    private var ended = false
    private var deadline: Task<Void, Never>?

    /// A sign-in left this long is given up.
    static let limit: Duration = .seconds(15 * 60)

    /// Starts `claude auth login`, with `arguments` after it (`--console`),
    /// in the agents' environment. Its attempt to open a browser on this
    /// computer is turned into nothing (`BROWSER`): the page goes to the
    /// user instead.
    init(claude: String, arguments: [String], environment: [String: String]) throws {
        let command = ServerPlatform.current.tools.command(claude, ["auth", "login"] + arguments)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        var environment = environment
        environment["BROWSER"] = "true"
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let chunks = output.fileHandleForReading.chunks
        let (statuses, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { exited.yield($0.terminationStatus); exited.finish() }
        try process.run()
        Task { [weak self] in
            for await chunk in chunks { self?.read(String(decoding: chunk, as: UTF8.self)) }
            var status: Int32 = -1
            for await value in statuses { status = value }
            self?.finish(status: status)
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    /// The code the sign-in page showed, as the user sent it.
    func submit(_ code: String) {
        let line = code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
    }

    func cancel() {
        guard !ended, process.isRunning else { return }
        ServerPlatform.current.processes.terminate(process.processIdentifier)
    }

    private func read(_ text: String) {
        said += text
        if url == nil, let found = Self.url(in: said) {
            url = found
            onURL(found)
        }
    }

    private func finish(status: Int32) {
        guard !ended else { return }
        ended = true
        deadline?.cancel()
        // The prompt ends without a newline: what comes after it is a line
        // of its own.
        let plain = Self.plain(said).replacing("Paste code here if prompted > ", with: "\n")
        let last = plain.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        onEnd(status == 0, last)
    }

    /// The sign-in page in what the command printed: the first web
    /// address, its terminal hyperlink markup taken off.
    static func url(in printed: String) -> String? {
        let plain = plain(printed)
        guard let start = plain.range(of: "https://") else { return nil }
        let rest = plain[start.lowerBound...]
        let end = rest.firstIndex { $0.isWhitespace } ?? rest.endIndex
        // Not yet the whole of it: wait for what ends the line.
        guard end != rest.endIndex else { return nil }
        return String(rest[..<end])
    }

    /// Text without terminal escapes (colours, OSC 8 hyperlinks).
    static func plain(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\u{1B}" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                if text[next] == "]" {
                    // OSC: to BEL, or to ESC \.
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex, text[cursor] != "\u{07}", text[cursor] != "\u{1B}" { cursor = text.index(after: cursor) }
                    if cursor < text.endIndex, text[cursor] == "\u{1B}" { cursor = text.index(after: cursor) }
                    index = cursor < text.endIndex ? text.index(after: cursor) : cursor
                    continue
                }
                if text[next] == "[" {
                    // CSI: to its final letter.
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex, !(text[cursor].isLetter) { cursor = text.index(after: cursor) }
                    index = cursor < text.endIndex ? text.index(after: cursor) : cursor
                    continue
                }
                index = text.index(after: next)
                continue
            }
            out.append(character)
            index = text.index(after: index)
        }
        return out
    }
}

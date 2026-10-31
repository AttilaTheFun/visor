import Foundation
import Synchronization

/// Apple's `container` (github.com/apple/container), run to its end: the
/// command line the Runner makes and keeps its container servers with.
public struct ContainerCLI: Sendable {
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

    public var installed: Bool { FileManager.default.isExecutableFile(atPath: tool) }

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

    /// The tool run with `arguments`, `input` its standard input; nil when
    /// it couldn't be started.
    public func run(_ arguments: [String], input: Data? = nil) -> Ran? {
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
        // Both read to their end on threads of their own: either may fill.
        let errors = Collected()
        Thread.detachNewThread { errors.add(err.fileHandleForReading.readDataToEndOfFile()) }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while !errors.done { usleep(1000) }
        return Ran(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), errors: errors.text)
    }

    /// A container as `inspect` tells of it.
    public struct Container: Equatable, Sendable {
        public var name: String
        public var status: String
        public var labels: [String: String]
        /// Its address on this computer's network for containers.
        public var address: String?

        init?(_ item: [String: Any]) {
            let configuration = item["configuration"] as? [String: Any] ?? [:]
            guard let id = configuration["id"] as? String else { return nil }
            name = id
            status = item["status"] as? String ?? ""
            labels = configuration["labels"] as? [String: String] ?? [:]
            let networks = item["networks"] as? [[String: Any]] ?? []
            address = networks.lazy.compactMap { $0["address"] as? String ?? $0["ipv4Address"] as? String }
                .first.map { String($0.split(separator: "/").first ?? Substring($0)) }
        }
    }

    /// The container named `name`, or nil when there is none.
    public func inspect(_ name: String) -> Container? {
        guard let read = run(["inspect", name]), read.status == 0,
              let items = (try? JSONSerialization.jsonObject(with: Data(read.output.utf8))) as? [[String: Any]] else { return nil }
        return items.first.flatMap { item in Container(item).map { container in
            var named = container
            if named.name.isEmpty { named.name = name }
            return named
        } }
    }

}

/// A pipe's bytes, read to their end on another thread.
private final class Collected: Sendable {
    private let read = Mutex<Data?>(nil)

    func add(_ chunk: Data) { read.withLock { $0 = chunk } }

    var done: Bool { read.withLock { $0 != nil } }

    var text: String { read.withLock { String(decoding: $0 ?? Data(), as: UTF8.self) } }
}

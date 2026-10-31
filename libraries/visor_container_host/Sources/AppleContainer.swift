import Foundation

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

    /// The tool run with `arguments`, `input` its standard input; nil when
    /// it couldn't be started.
    func run(_ arguments: [String], input: Data? = nil) -> Tool.Ran? {
        Tool(tool).run(arguments, input: input)
    }

    /// Rosetta is installed on this Mac: x86_64 Linux programs run in a
    /// container too (Android's build tools come for x86_64 alone).
    static var hasRosetta: Bool { FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") }
}

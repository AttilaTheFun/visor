import AgentProtocol
import Foundation

/// How a harness is started: its program and arguments, for an agent's
/// spec; or, for `echo`, no program at all (AgentCore answers each message
/// with its words, so a whole flow can be proven without a model).
public struct HarnessLaunch: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The built-in echo harness.
    public static let echo = HarnessLaunch(executable: "", arguments: ["echo"])

    public var isEcho: Bool { self == .echo }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unsupported(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .unsupported(let harness): "the harness \(harness) isn't supported yet"
            case .notFound(let name): "\(name) isn't on PATH"
            }
        }
    }

    /// Claude Code in print mode, talking stream JSON both ways, its stdin
    /// kept open for each turn: `claude -p`, for any harness, is the idea.
    /// `program` overrides where `claude` is (a test's stand-in).
    public static func claude(_ spec: AgentProtocol_V1_AgentSpec, program: String? = nil,
                              path: String? = ProcessInfo.processInfo.environment["PATH"]) throws(Problem) -> HarnessLaunch {
        guard let executable = program ?? locate("claude", path: path) else { throw .notFound("claude") }
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if !spec.model.isEmpty { arguments += ["--model", spec.model] }
        if !spec.resumeSessionID.isEmpty { arguments += ["--resume", spec.resumeSessionID] }
        if spec.skipPermissions { arguments += ["--permission-mode", "bypassPermissions"] }
        return HarnessLaunch(executable: executable, arguments: arguments)
    }

    /// The launch for `spec`'s harness ("claude" when it names none).
    public static func `for`(_ spec: AgentProtocol_V1_AgentSpec, claudeProgram: String? = nil) throws(Problem) -> HarnessLaunch {
        switch spec.harness {
        case "claude", "": try claude(spec, program: claudeProgram)
        case "echo": .echo
        default: throw .unsupported(spec.harness)
        }
    }

    /// Where `name` is on `path`, if anywhere.
    static func locate(_ name: String, path: String?) -> String? {
        for folder in (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(folder)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

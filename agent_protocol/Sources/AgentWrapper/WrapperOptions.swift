import AgentProtocol
import Foundation

/// What the wrapper is told to run. As a runner starts it, from the
/// environment (Shireworks' contract, 12 Nov 2026):
///
/// - `AGENT_ID`: `<uuid>@<dispatcher URL>`;
/// - `AGENT_JOB`: the job as JSON, `{agent, dispatcherURL, title, prompt,
///   sourceURL, repository, ref, harness?, model?, effort?, labels,
///   workingDirectory?, driverURL?}`;
/// - `AGENT_DISPATCHER_URL`: whom it reports Started, Completed and Failed to;
/// - `AGENT_DRIVER_URL`: the driver it dials, if any;
/// - `AGENT_RUNNER`: the runner's name.
///
/// By hand, the same as flags:
///
///     agent-wrapper --agent <uuid> --dispatcher <url> [--harness claude|echo] [--model m] [--effort e]
///                   [--cwd dir] [--title t] [--prompt text] [--resume id] [--skip-permissions] [--label key=value]…
///
/// AGENT_WRAPPER_CLAUDE stands in for `claude`.
public struct WrapperOptions: Sendable, Equatable {
    public var agent = AgentProtocol_V1_AgentID()
    public var spec = AgentProtocol_V1_AgentSpec()
    public var driverURL: String?
    public var dispatcherURL: String?
    public var runner: String?
    public var claudeProgram: String?

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unknown(String)
        case bad(String)

        public var description: String {
            switch self {
            case .missing(let what): "\(what) is needed"
            case .unknown(let what): "\(what)?"
            case .bad(let what): what
            }
        }
    }

    public static let usage = """
        Usage: agent-wrapper --agent <uuid> --dispatcher <url> [--harness claude|echo] [--model m] [--effort e]
                             [--cwd dir] [--title t] [--prompt text] [--resume id] [--skip-permissions] [--label key=value]…
        Or, as a runner starts it: AGENT_ID=<uuid>@<url> AGENT_JOB=<json> [AGENT_DISPATCHER_URL] [AGENT_DRIVER_URL] [AGENT_RUNNER].
        """

    public init(arguments: [String], environment: [String: String]) throws(Problem) {
        spec.harness = "claude"
        if let id = environment["AGENT_ID"], !id.isEmpty {
            guard let at = id.firstIndex(of: "@") else { throw .bad("AGENT_ID is <uuid>@<dispatcher URL>") }
            agent.uuid = String(id[..<at])
            agent.dispatcherURL = String(id[id.index(after: at)...])
        }
        if let job = environment["AGENT_JOB"], !job.isEmpty { try take(job: job) }
        try take(arguments: arguments)
        guard !agent.uuid.isEmpty else { throw .missing("--agent or AGENT_ID") }
        guard !agent.dispatcherURL.isEmpty else { throw .missing("--dispatcher or AGENT_ID") }
        driverURL = Self.given(environment["AGENT_DRIVER_URL"]) ?? driverURL
        dispatcherURL = Self.given(environment["AGENT_DISPATCHER_URL"])
        runner = Self.given(environment["AGENT_RUNNER"])
        claudeProgram = Self.given(environment["AGENT_WRAPPER_CLAUDE"])
    }

    private static func given(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// The job's JSON (AGENT_JOB).
    private mutating func take(job: String) throws(Problem) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(job.utf8))) as? [String: Any] else {
            throw .bad("AGENT_JOB isn't a JSON object")
        }
        func string(_ key: String) -> String { object[key] as? String ?? "" }
        if !string("agent").isEmpty { agent.uuid = string("agent") }
        if !string("dispatcherURL").isEmpty { agent.dispatcherURL = string("dispatcherURL") }
        if !string("harness").isEmpty { spec.harness = string("harness") }
        spec.title = string("title")
        spec.prompt = string("prompt")
        spec.model = string("model")
        spec.effort = string("effort")
        spec.workingDirectory = string("workingDirectory")
        for (key, value) in [("sourceURL", string("sourceURL")), ("repository", string("repository")), ("ref", string("ref"))] where !value.isEmpty {
            spec.labels[key] = value
        }
        for label in object["labels"] as? [String] ?? [] { spec.labels[label] = "" }
        if !string("driverURL").isEmpty { driverURL = string("driverURL") }
    }

    private mutating func take(arguments: [String]) throws(Problem) {
        var rest = arguments[...]
        func value(_ flag: String) throws(Problem) -> String {
            guard let next = rest.popFirst() else { throw .missing("a value for \(flag)") }
            return next
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--agent": agent.uuid = try value(flag)
            case "--dispatcher": agent.dispatcherURL = try value(flag)
            case "--harness": spec.harness = try value(flag)
            case "--model": spec.model = try value(flag)
            case "--effort": spec.effort = try value(flag)
            case "--cwd": spec.workingDirectory = try value(flag)
            case "--title": spec.title = try value(flag)
            case "--prompt": spec.prompt = try value(flag)
            case "--resume": spec.resumeSessionID = try value(flag)
            case "--skip-permissions": spec.skipPermissions = true
            case "--label":
                let pair = try value(flag)
                guard let equals = pair.firstIndex(of: "=") else { throw .bad("--label takes key=value") }
                spec.labels[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            default: throw .unknown(flag)
            }
        }
    }
}

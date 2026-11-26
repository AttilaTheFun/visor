// A session's agent to run in the Sessions container
// (ContainerEngine.startWrapper, step 4's): what agent_protocol's
// agent-wrapper is told, as a runner tells it (its README's contract, and
// Shireworks' runner's): who the agent is and whom it reports to, its job,
// its token, its working folder, and what else its harness's environment
// needs (a sign-in, Claude's folder). Nothing here knows agent_protocol's
// types: the job is its JSON (AGENT_JOB), written by `jobJSON`.

import Foundation

public struct ContainerSession: Equatable, Sendable {
    /// The agent's UUID, as the dispatcher wrote it: AGENT_ID's first part,
    /// the exec's id, and its log's name (`logs/<id>.log`).
    public var id: String
    /// AGENT_ID's second part: the dispatcher the agent is one of.
    public var dispatcherURL: String
    /// Whom it reports Started, Completed and Failed to
    /// (AGENT_DISPATCHER_URL); nil: no one (a session Visor drives alone).
    public var reportsTo: String?
    public var title: String
    public var prompt: String
    /// claude (nil) or another harness the wrapper knows (echo).
    public var harness: String?
    public var model: String?
    public var effort: String?
    /// Where it works, at the same path in the guest as on the Mac (under
    /// Sessions, or the checkouts' folder). Nil: the wrapper's own,
    /// `<AGENT_SESSIONS_DIR>/<Harness>/<id>`.
    public var workingDirectory: String?
    /// The harness's own session to resume (a session that carries on).
    public var resumeSessionID: String?
    /// Job.skip_permissions: true, it acts; false, it asks its driver
    /// (`mcp__visor__approve`); nil, the job doesn't say, and it acts (the
    /// wrapper is passed `--skip-permissions`, as Shireworks' container
    /// runner passes it unless the job says false).
    public var skipPermissions: Bool?
    public var labels: [String]
    /// A moved session's repositories, cloned by the wrapper under
    /// `sourcesDirectory` before it resumes (AGENT_JOB's `sources`): each
    /// its clone URL, its branch, and its folder's name.
    public var sources: [Source]
    /// The agent's token (Job.token, a JWT): its bearer to the driver and
    /// dispatcher, on the wrapper's standard input alone (AGENT_TOKEN_FD=0;
    /// never in an environment, AGENT_JOB or argv).
    public var token: String?
    /// AGENT_RUNNER: who runs it.
    public var runner: String
    /// Where a resumed session's sources are cloned (AGENT_SOURCES_DIR).
    public var sourcesDirectory: String?
    /// A stand-in for `claude` (AGENT_WRAPPER_CLAUDE: a test's); nil, the
    /// image's `claude` on its PATH (/usr/local/bin/claude).
    public var claudeProgram: String?
    /// More for the harness's environment (CLAUDE_CODE_OAUTH_TOKEN,
    /// CLAUDE_CONFIG_DIR), set over the rest but never over the wrapper's
    /// own AGENT_* contract.
    public var environment: [String: String]

    public init(id: String, dispatcherURL: String, reportsTo: String? = nil, title: String = "", prompt: String = "", harness: String? = nil,
                model: String? = nil, effort: String? = nil, workingDirectory: String? = nil, resumeSessionID: String? = nil,
                skipPermissions: Bool? = nil, labels: [String] = [], sources: [Source] = [], token: String? = nil,
                runner: String = ContainerEngine.name,
                sourcesDirectory: String? = nil, claudeProgram: String? = nil, environment: [String: String] = [:]) {
        self.id = id
        self.dispatcherURL = dispatcherURL
        self.reportsTo = reportsTo
        self.title = title
        self.prompt = prompt
        self.harness = harness
        self.model = model
        self.effort = effort
        self.workingDirectory = workingDirectory
        self.resumeSessionID = resumeSessionID
        self.skipPermissions = skipPermissions
        self.labels = labels
        self.sources = sources
        self.token = token
        self.runner = runner
        self.sourcesDirectory = sourcesDirectory
        self.claudeProgram = claudeProgram
        self.environment = environment
    }

    /// AGENT_JOB, as agent-wrapper's WrapperOptions reads it: the job with
    /// the driver the agent dials, the optional keys only when set, and
    /// `skipPermissions` only when the job says (it has presence). Sorted
    /// keys, so the same session is the same JSON.
    public func jobJSON(driverURL: String) -> String {
        var object: [String: Any] = ["agent": id, "dispatcherURL": dispatcherURL, "title": title, "prompt": prompt, "sourceURL": "",
                                     "repository": "", "ref": "", "labels": labels, "driverURL": driverURL]
        for (key, value) in [("harness", harness), ("model", model), ("effort", effort), ("workingDirectory", workingDirectory),
                             ("resumeSessionID", resumeSessionID)] {
            if let value, !value.isEmpty { object[key] = value }
        }
        if let skipPermissions { object["skipPermissions"] = skipPermissions }
        if !sources.isEmpty {
            object["sources"] = sources.map { ["repository": $0.repository, "ref": $0.ref, "name": $0.name] }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension ContainerSession {
    /// A repository a resumed session works in (agent_protocol's Source).
    public struct Source: Equatable, Sendable {
        public var repository: String
        public var ref: String
        public var name: String

        public init(repository: String, ref: String = "", name: String = "") {
            self.repository = repository
            self.ref = ref
            self.name = name
        }
    }
}

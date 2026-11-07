/// How the gate's checks read GitHub, with the session's token: the proxy's
/// own requests to api.github.com, before a write goes on (GateChecker). A
/// test gives a table of answers.
protocol GitHubReading: Sendable {
    /// `GET https://api.github.com<path>` (its query included).
    func get(_ path: String) async -> GitHubAnswer
    /// `POST https://api.github.com/graphql` with this query and variables.
    func graphQL(_ query: String, variables: [String: GateJSON]) async -> GitHubAnswer
}

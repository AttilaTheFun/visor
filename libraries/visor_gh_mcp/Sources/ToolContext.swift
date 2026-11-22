import Foundation

public struct ToolContext: Sendable {
    public let caller: Caller
    public let rules: RepoRules
    public let github: GitHub
    public let services: Services
    let note: CallNote

    /// The `repo` argument, checked against the allowed repositories.
    func repo(_ arguments: Arguments) throws -> RepoName {
        let repo = try rules.check(arguments.string("repo") ?? "")
        note.repo = repo.description
        return repo
    }
}

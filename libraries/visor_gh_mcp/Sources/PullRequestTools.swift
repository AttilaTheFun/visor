import Foundation

enum PullRequestTools {
    static let summaryFields: [(String, [String])] = [
        ("number", ["number"]), ("title", ["title"]), ("state", ["state"]), ("draft", ["draft"]),
        ("merged", ["merged"]), ("url", ["html_url"]), ("author", ["user", "login"]),
        ("head", ["head", "ref"]), ("head_sha", ["head", "sha"]), ("base", ["base", "ref"]),
        ("updated_at", ["updated_at"]),
    ]

    /// `branch` or `owner:branch` in the repository's own account: the
    /// branch.
    static func branch(_ text: String, in repo: RepoName, argument: String) throws -> String {
        var branch = text
        if let colon = text.firstIndex(of: ":") {
            guard text[..<colon].caseInsensitiveCompare(repo.owner) == .orderedSame else {
                throw ToolError.refused("\(argument) is a branch of \(repo.owner)'s: \(text)")
            }
            branch = String(text[text.index(after: colon)...])
        }
        guard Refs.isValid(branch) else { throw ToolError.invalid("\(argument) is not a branch name: \(text)") }
        return branch
    }

    static func create(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let head = try branch(arguments.string("head")!, in: repo, argument: "head")
        let base = try branch(arguments.string("base")!, in: repo, argument: "base")
        guard head != base else { throw ToolError.invalid("head and base are the same branch: \(head)") }
        let pull = try await context.github.json(repo, "POST", "/repos/\(repo)/pulls", body: [
            "title": .string(arguments.string("title")!),
            "head": .string(head),
            "base": .string(base),
            "body": .string(arguments.string("body") ?? ""),
            "draft": .bool(arguments.bool("draft") ?? false),
        ])
        return pick(pull, summaryFields).text()
    }

    static func edit(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        var changes: [String: JSON] = [:]
        if let title = arguments.string("title") { changes["title"] = .string(title) }
        if let body = arguments.string("body") { changes["body"] = .string(body) }
        guard !changes.isEmpty else { throw ToolError.invalid("pr_edit changes a title or a body: give one") }
        let number = arguments.int("number")!
        let pull = try await context.github.json(repo, "PATCH", "/repos/\(repo)/pulls/\(number)", body: .object(changes))
        return pick(pull, summaryFields).text()
    }

    static func comment(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let comment = try await context.github.json(repo, "POST", "/repos/\(repo)/issues/\(number)/comments", body: [
            "body": .string(arguments.string("body")!),
        ])
        return pick(comment, [("id", ["id"]), ("url", ["html_url"]), ("created_at", ["created_at"])]).text()
    }

    static func view(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let pull = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)")
        let reviews = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)/reviews", query: ["per_page": "100"])
        var view = pick(pull, summaryFields + [
            ("mergeable", ["mergeable"]), ("mergeable_state", ["mergeable_state"]), ("rebaseable", ["rebaseable"]),
            ("merged_by", ["merged_by", "login"]), ("created_at", ["created_at"]), ("commits", ["commits"]),
            ("additions", ["additions"]), ("deletions", ["deletions"]), ("changed_files", ["changed_files"]),
            ("body", ["body"]),
        ])
        var extra: [String: JSON] = [
            "requested_reviewers": .array((pull["requested_reviewers"]?.arrayValue ?? []).map { $0["login"] ?? .null }),
            "reviews": .array((reviews.arrayValue ?? []).map { review in
                var summary = pick(review, [("author", ["user", "login"]), ("state", ["state"]), ("submitted_at", ["submitted_at"]),
                                            ("commit", ["commit_id"])])
                if let body = review["body"]?.stringValue, !body.isEmpty {
                    summary = merge(summary, ["body": .string(body.count > 1000 ? String(body.prefix(1000)) + "…" : body)])
                }
                return summary
            }),
        ]
        if pull["mergeable"] == .null && pull["state"]?.stringValue == "open" {
            extra["mergeable_note"] = "GitHub is still working out mergeability; ask again in a few seconds."
        }
        view = merge(view, extra)
        return view.text()
    }

    static func list(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        var query = ["state": arguments.string("state") ?? "open", "per_page": "50"]
        if let head = arguments.string("head") {
            query["head"] = "\(repo.owner):\(try branch(head, in: repo, argument: "head"))"
        }
        let pulls = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls", query: query)
        let items = (pulls.arrayValue ?? []).map { pick($0, summaryFields) }
        return JSON.array(items).text()
    }
}

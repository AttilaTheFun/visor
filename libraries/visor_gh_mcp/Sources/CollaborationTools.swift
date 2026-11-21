import Foundation

/// Round two: reads anywhere in an allowed repository, and the writes that
/// lose nothing (comments, replies, COMMENT reviews, issues opened and
/// edited, a pull request to draft and back). Policy has the never-list.
enum CollaborationTools {
    static func clip(_ text: String?, _ limit: Int) -> JSON {
        guard let text else { return .null }
        return .string(text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count) characters; the first \(limit) shown)" : text)
    }

    static func labels(_ text: String?) -> JSON? {
        guard let text else { return nil }
        return .array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != "" })
    }

    static func ref(_ arguments: Arguments, _ name: String) throws -> String? {
        guard let ref = arguments.string(name) else { return nil }
        guard Refs.isReadableRef(ref) else { throw ToolError.invalid("\(name) is a branch, tag or commit SHA: \(ref)") }
        return ref
    }

    // MARK: Reads

    static func reviewComments(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let comments = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)/comments", query: ["per_page": "100"])
        return JSON.array((comments.arrayValue ?? []).map { comment in
            merge(pick(comment, [
                ("id", ["id"]), ("in_reply_to", ["in_reply_to_id"]), ("author", ["user", "login"]), ("path", ["path"]),
                ("line", ["line"]), ("original_line", ["original_line"]), ("start_line", ["start_line"]), ("side", ["side"]),
                ("commit", ["commit_id"]), ("created_at", ["created_at"]), ("url", ["html_url"]),
            ]), ["body": clip(comment["body"]?.stringValue, 4000)])
        }).text()
    }

    static func files(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let files = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)/files", query: ["per_page": "100"])
        return JSON.array((files.arrayValue ?? []).map(fileSummary)).text()
    }

    static func fileSummary(_ file: JSON) -> JSON {
        merge(pick(file, [("path", ["filename"]), ("status", ["status"]), ("additions", ["additions"]), ("deletions", ["deletions"]),
                          ("previous_path", ["previous_filename"])]),
              ["patch": clip(file["patch"]?.stringValue, 4000)])
    }

    static let commitFields: [(String, [String])] = [
        ("sha", ["sha"]), ("author", ["commit", "author", "name"]), ("date", ["commit", "author", "date"]), ("url", ["html_url"]),
    ]

    static func commitSummary(_ commit: JSON) -> JSON {
        let message = commit["commit"]?["message"]?.stringValue ?? ""
        return merge(pick(commit, commitFields), ["title": .string(String(message.split(whereSeparator: \.isNewline).first ?? ""))])
    }

    static func commits(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        var query = ["per_page": String(arguments.int("limit") ?? 20)]
        if let ref = try ref(arguments, "ref") { query["sha"] = ref }
        if let path = arguments.string("path") { query["path"] = path }
        let commits = try await context.github.json(repo, "GET", "/repos/\(repo)/commits", query: query)
        return JSON.array((commits.arrayValue ?? []).map(commitSummary)).text()
    }

    static func commitView(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let ref = try ref(arguments, "ref")!
        let commit = try await context.github.json(repo, "GET", "/repos/\(repo)/commits/\(encodeSegment(ref))")
        return merge(pick(commit, commitFields + [("additions", ["stats", "additions"]), ("deletions", ["stats", "deletions"])]), [
            "message": commit["commit"]?["message"] ?? .null,
            "parents": .array((commit["parents"]?.arrayValue ?? []).map { $0["sha"] ?? .null }),
            "files": .array((commit["files"]?.arrayValue ?? []).prefix(100).map(fileSummary)),
        ]).text()
    }

    static func compare(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let base = try ref(arguments, "base")!, head = try ref(arguments, "head")!
        let comparison = try await context.github.json(repo, "GET", "/repos/\(repo)/compare/\(encodeSegment(base))...\(encodeSegment(head))")
        return merge(pick(comparison, [("status", ["status"]), ("ahead_by", ["ahead_by"]), ("behind_by", ["behind_by"]),
                                       ("total_commits", ["total_commits"]), ("merge_base", ["merge_base_commit", "sha"]), ("url", ["html_url"])]), [
            "commits": .array((comparison["commits"]?.arrayValue ?? []).suffix(100).map(commitSummary)),
            "files": .array((comparison["files"]?.arrayValue ?? []).prefix(100).map { file in
                pick(file, [("path", ["filename"]), ("status", ["status"]), ("additions", ["additions"]), ("deletions", ["deletions"])])
            }),
        ]).text()
    }

    static func branches(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let branches = try await context.github.json(repo, "GET", "/repos/\(repo)/branches", query: ["per_page": "100"])
        return JSON.array((branches.arrayValue ?? []).map {
            pick($0, [("name", ["name"]), ("sha", ["commit", "sha"]), ("protected", ["protected"])])
        }).text()
    }

    static let issueFields: [(String, [String])] = [
        ("number", ["number"]), ("title", ["title"]), ("state", ["state"]), ("author", ["user", "login"]),
        ("comments", ["comments"]), ("updated_at", ["updated_at"]), ("url", ["html_url"]),
    ]

    static func issueSummary(_ issue: JSON) -> JSON {
        merge(pick(issue, issueFields), ["labels": .array((issue["labels"]?.arrayValue ?? []).map { $0["name"] ?? .null })])
    }

    static func issues(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        var query = ["state": arguments.string("state") ?? "open", "per_page": "50"]
        if let labels = arguments.string("labels") { query["labels"] = labels }
        let issues = try await context.github.json(repo, "GET", "/repos/\(repo)/issues", query: query)
        // GitHub's issues include pull requests; pr_list has those.
        return JSON.array((issues.arrayValue ?? []).filter { $0["pull_request"] == nil }.map(issueSummary)).text()
    }

    static func issueView(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let issue = try await context.github.json(repo, "GET", "/repos/\(repo)/issues/\(number)")
        let comments = try await context.github.json(repo, "GET", "/repos/\(repo)/issues/\(number)/comments", query: ["per_page": "100"])
        return merge(issueSummary(issue), [
            "body": clip(issue["body"]?.stringValue, 20000),
            "is_pull_request": .bool(issue["pull_request"] != nil),
            "comment_list": .array((comments.arrayValue ?? []).map { comment in
                merge(pick(comment, [("id", ["id"]), ("author", ["user", "login"]), ("created_at", ["created_at"])]),
                      ["body": clip(comment["body"]?.stringValue, 4000)])
            }),
        ]).text()
    }

    // MARK: Writes that lose nothing

    static func reviewCommentReply(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!, comment = arguments.int("comment_id")!
        let reply = try await context.github.json(repo, "POST", "/repos/\(repo)/pulls/\(number)/comments/\(comment)/replies",
                                                  body: ["body": .string(arguments.string("body")!)])
        return pick(reply, [("id", ["id"]), ("url", ["html_url"]), ("path", ["path"]), ("line", ["line"])]).text()
    }

    /// A review whose event is COMMENT, always.
    static func review(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let review = try await context.github.json(repo, "POST", "/repos/\(repo)/pulls/\(number)/reviews",
                                                   body: ["body": .string(arguments.string("body")!), "event": "COMMENT"])
        return pick(review, [("id", ["id"]), ("state", ["state"]), ("url", ["html_url"])]).text()
    }

    static func issueCreate(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        var body: [String: JSON] = ["title": .string(arguments.string("title")!), "body": .string(arguments.string("body") ?? "")]
        if let labels = labels(arguments.string("labels")) { body["labels"] = labels }
        let issue = try await context.github.json(repo, "POST", "/repos/\(repo)/issues", body: .object(body))
        return issueSummary(issue).text()
    }

    static func issueComment(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let comment = try await context.github.json(repo, "POST", "/repos/\(repo)/issues/\(number)/comments",
                                                    body: ["body": .string(arguments.string("body")!)])
        return pick(comment, [("id", ["id"]), ("url", ["html_url"])]).text()
    }

    /// Title, body and labels; never its state.
    static func issueEdit(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        var changes: [String: JSON] = [:]
        if let title = arguments.string("title") { changes["title"] = .string(title) }
        if let body = arguments.string("body") { changes["body"] = .string(body) }
        if let labels = labels(arguments.string("labels")) { changes["labels"] = labels }
        guard !changes.isEmpty else { throw ToolError.invalid("issue_edit changes a title, body or labels: give one") }
        let issue = try await context.github.json(repo, "PATCH", "/repos/\(repo)/issues/\(arguments.int("number")!)", body: .object(changes))
        return issueSummary(issue).text()
    }

    /// Ready for review, or back to draft (GraphQL's mutations; REST has
    /// none).
    static func readyForReview(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let ready = arguments.bool("ready") ?? true
        let pull = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)")
        guard let id = pull["node_id"]?.stringValue else { throw ToolError.failed("GitHub gave pull request \(number) no node id") }
        // Only a pull request not yet as asked is changed: a draft made ready,
        // or a ready one made a draft.
        if (pull["draft"]?.boolValue ?? false) == ready {
            let mutation = Policy.readyMutations[ready ? 0 : 1]
            let result = try await context.github.json(repo, "POST", "/graphql", body: ["query": .string(mutation), "variables": ["id": .string(id)]])
            if let message = result["errors"]?.arrayValue?.first?["message"]?.stringValue {
                throw ToolError.failed("GitHub refused: \(Redact.line(message))")
            }
            // What GitHub says the pull request is now: a mutation can answer
            // without errors and still have changed nothing.
            let field = ready ? "markPullRequestReadyForReview" : "convertPullRequestToDraft"
            let isDraft = result["data"]?[field]?["pullRequest"]?["isDraft"]?.boolValue
            if isDraft != !ready {
                let after = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)")
                if after["draft"]?.boolValue != !ready {
                    throw ToolError.failed("GitHub answered but pull request #\(number) is still \(ready ? "a draft" : "ready for review"): \(Redact.line(result.text()))")
                }
            }
        }
        return "Pull request #\(number) of \(repo) is \(ready ? "ready for review" : "a draft")."
    }
}

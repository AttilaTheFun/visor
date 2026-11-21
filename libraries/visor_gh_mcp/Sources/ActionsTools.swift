import Foundation

enum ActionsTools {
    static func checks(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let ref = arguments.string("ref")!
        guard Refs.isReadableRef(ref) else { throw ToolError.invalid("ref is a commit SHA, branch or tag: \(ref)") }
        let segment = encodeSegment(ref)
        let runs = try await context.github.json(repo, "GET", "/repos/\(repo)/commits/\(segment)/check-runs", query: ["per_page": "100"])
        // Commit statuses need the app's statuses permission, which a
        // repository may not grant: its check runs are answered without them.
        let statusResponse = try await context.github.send(repo, "GET", "/repos/\(repo)/commits/\(segment)/status", query: ["per_page": "100"])
        let statusesReadable = statusResponse.isSuccess
        guard statusesReadable || [403, 404].contains(statusResponse.status) else {
            throw ToolError.failed(GitHub.describe(statusResponse, method: "GET", path: "/repos/\(repo)/commits/\(segment)/status"))
        }
        let status = statusesReadable ? ((try? JSON.parse(statusResponse.body)) ?? .null) : .null
        var passed = 0, failed = 0, pending = 0
        let checkRuns: [JSON] = (runs["check_runs"]?.arrayValue ?? []).map { run in
            if run["status"]?.stringValue != "completed" {
                pending += 1
            } else if ["success", "neutral", "skipped"].contains(run["conclusion"]?.stringValue ?? "") {
                passed += 1
            } else {
                failed += 1
            }
            return pick(run, [("name", ["name"]), ("status", ["status"]), ("conclusion", ["conclusion"]), ("app", ["app", "slug"]),
                              ("url", ["html_url"]), ("started_at", ["started_at"]), ("completed_at", ["completed_at"])])
        }
        let statuses: [JSON] = (status["statuses"]?.arrayValue ?? []).map { item in
            switch item["state"]?.stringValue {
            case "success": passed += 1
            case "pending": pending += 1
            default: failed += 1
            }
            return pick(item, [("context", ["context"]), ("state", ["state"]), ("description", ["description"]), ("url", ["target_url"])])
        }
        var result: [String: JSON] = [
            "ref": .string(ref),
            "sha": status["sha"] ?? runs["check_runs"]?.arrayValue?.first?["head_sha"] ?? .null,
            "summary": .string("\(passed) passed, \(failed) failed, \(pending) pending"),
            "check_runs": .array(checkRuns),
            "statuses": .array(statuses),
        ]
        if !statusesReadable {
            result["statuses_note"] = .string("commit statuses aren't readable here (GitHub answered \(statusResponse.status)): check runs only")
        }
        if let total = runs["total_count"]?.intValue, total > checkRuns.count {
            result["note"] = .string("\(total) check runs; the first \(checkRuns.count) are shown")
        }
        return JSON.object(result).text()
    }

    static let runFields: [(String, [String])] = [
        ("id", ["id"]), ("workflow", ["name"]), ("title", ["display_title"]), ("number", ["run_number"]),
        ("attempt", ["run_attempt"]), ("event", ["event"]), ("branch", ["head_branch"]), ("sha", ["head_sha"]),
        ("status", ["status"]), ("conclusion", ["conclusion"]), ("created_at", ["created_at"]), ("url", ["html_url"]),
    ]

    static func runs(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        var query = ["per_page": String(arguments.int("limit") ?? 10)]
        if let branch = arguments.string("branch") {
            guard Refs.isValid(branch) else { throw ToolError.invalid("branch is not a branch name: \(branch)") }
            query["branch"] = branch
        }
        if let event = arguments.string("event") {
            guard event.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_") }) else { throw ToolError.invalid("event is a word like push: \(event)") }
            query["event"] = event
        }
        let runs = try await context.github.json(repo, "GET", "/repos/\(repo)/actions/runs", query: query)
        return JSON.array((runs["workflow_runs"]?.arrayValue ?? []).map { pick($0, runFields) }).text()
    }

    static func jobs(_ repo: RepoName, _ runID: Int, _ context: ToolContext) async throws -> [JSON] {
        let jobs = try await context.github.json(repo, "GET", "/repos/\(repo)/actions/runs/\(runID)/jobs", query: ["per_page": "100"])
        return jobs["jobs"]?.arrayValue ?? []
    }

    static func view(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let runID = arguments.int("run_id")!
        let run = try await context.github.json(repo, "GET", "/repos/\(repo)/actions/runs/\(runID)")
        let jobs = try await jobs(repo, runID, context).map { job -> JSON in
            let failedSteps = (job["steps"]?.arrayValue ?? [])
                .filter { ["failure", "timed_out", "cancelled"].contains($0["conclusion"]?.stringValue ?? "") }
                .map { $0["name"] ?? .null }
            var summary = pick(job, [("id", ["id"]), ("name", ["name"]), ("status", ["status"]), ("conclusion", ["conclusion"]),
                                     ("started_at", ["started_at"]), ("completed_at", ["completed_at"]), ("url", ["html_url"])])
            if !failedSteps.isEmpty { summary = merge(summary, ["failed_steps": .array(failedSteps)]) }
            return summary
        }
        let artifacts = try await context.github.json(repo, "GET", "/repos/\(repo)/actions/runs/\(runID)/artifacts", query: ["per_page": "100"])
        let view = merge(pick(run, runFields), [
            "jobs": .array(jobs),
            "artifacts": .array((artifacts["artifacts"]?.arrayValue ?? []).map {
                pick($0, [("name", ["name"]), ("size_in_bytes", ["size_in_bytes"]), ("expired", ["expired"]), ("expires_at", ["expires_at"])])
            }),
        ])
        return view.text()
    }

    static func log(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let runID = arguments.int("run_id")!
        let maxLines = arguments.int("max_lines") ?? 200
        let failedOnly = arguments.bool("failed_only") ?? false
        var jobs = try await jobs(repo, runID, context)
        let names = jobs.compactMap { $0["name"]?.stringValue }
        if let job = arguments.string("job") {
            let matching = jobs.filter { $0["id"]?.intValue.map(String.init) == job || $0["name"]?.stringValue == job }
            let containing = jobs.filter { ($0["name"]?.stringValue ?? "").localizedCaseInsensitiveContains(job) }
            jobs = matching.isEmpty ? containing : matching
            guard !jobs.isEmpty else {
                throw ToolError.invalid("run \(runID) has no job \(job) (its jobs: \(names.joined(separator: ", ")))")
            }
        }
        if failedOnly {
            jobs = jobs.filter { ["failure", "timed_out", "cancelled", "startup_failure"].contains($0["conclusion"]?.stringValue ?? "") }
            guard !jobs.isEmpty else { return "No job of run \(runID) failed\(arguments.string("job").map { " among those matching \($0)" } ?? "")." }
        }
        guard !jobs.isEmpty else { return "Run \(runID) has no jobs." }
        var text = ""
        for job in jobs {
            guard let id = job["id"]?.intValue else { continue }
            let name = job["name"]?.stringValue ?? "job"
            let conclusion = job["conclusion"]?.stringValue ?? job["status"]?.stringValue ?? "?"
            text += "== \(name) (job \(id), \(conclusion)) ==\n"
            let response = try await context.github.send(repo, "GET", "/repos/\(repo)/actions/jobs/\(id)/logs")
            let log: GitHubResponse
            do {
                log = try await context.github.followed(response, what: "job \(id)'s log")
            } catch let error as ToolError {
                text += "(no log: \(error.text))\n"
                continue
            }
            let failed = conclusion == "failure" || conclusion == "timed_out"
            text += trim(log.text, maxLines: maxLines, toLastError: failed)
            if text.utf8.count > 400_000 {
                text += "\n(stopped: the logs are longer than 400 KB; ask for one job, or fewer lines)\n"
                break
            }
        }
        return text
    }

    /// A log's last `maxLines` lines (ending a few lines after its last
    /// ##[error] when `toLastError`), timestamps taken off.
    static func trim(_ log: String, maxLines: Int, toLastError: Bool) -> String {
        var lines = log.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        lines = lines.map(stripTimestamp)
        while lines.last?.isEmpty == true { lines.removeLast() }
        var end = lines.count
        if toLastError, let lastError = lines.lastIndex(where: { $0.contains("##[error]") }) {
            end = min(lines.count, lastError + 6)
        }
        let start = max(0, end - maxLines)
        var text = ""
        if start > 0 { text += "… \(start) earlier lines\n" }
        text += lines[start..<end].joined(separator: "\n") + "\n"
        if end < lines.count { text += "… \(lines.count - end) later lines\n" }
        return text
    }

    /// `2026-10-29T01:02:03.4567890Z ` off a line's start.
    static func stripTimestamp(_ line: String) -> String {
        let characters = Array(line.prefix(40))
        guard characters.count > 20, characters[4] == "-", characters[7] == "-", characters[10] == "T",
              let z = characters.firstIndex(of: "Z"), z < 34, z + 1 < characters.count, characters[z + 1] == " " else { return line }
        return String(line.dropFirst(z + 2))
    }
}

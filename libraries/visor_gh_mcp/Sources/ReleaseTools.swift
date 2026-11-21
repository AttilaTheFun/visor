import Foundation

enum ReleaseTools {
    static let fields: [(String, [String])] = [
        ("id", ["id"]), ("tag", ["tag_name"]), ("title", ["name"]), ("draft", ["draft"]), ("prerelease", ["prerelease"]),
        ("target", ["target_commitish"]), ("created_at", ["created_at"]), ("published_at", ["published_at"]), ("url", ["html_url"]),
    ]

    /// A draft, always: `draft` is sent true and nothing that publishes is.
    static func draft(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let tag = arguments.string("tag")!, target = arguments.string("target")!
        guard Refs.isValid(tag) else { throw ToolError.invalid("tag is not a name git would take: \(tag)") }
        guard Refs.isValid(target) else { throw ToolError.invalid("target is a branch or commit SHA: \(target)") }
        let release = try await context.github.json(repo, "POST", "/repos/\(repo)/releases", body: [
            "tag_name": .string(tag),
            "target_commitish": .string(target),
            "name": .string(arguments.string("title")!),
            "body": .string(arguments.string("body") ?? ""),
            "draft": true,
        ])
        guard release["draft"]?.boolValue == true else {
            throw ToolError.failed("GitHub made release \(release["id"]?.intValue ?? 0) but did not say it is a draft; check it")
        }
        return pick(release, fields).text()
    }

    /// Only a release that is a draft when asked; the change never sends
    /// `draft` or anything that would publish it. It sends the draft's own
    /// tag back unchanged: GitHub resets a draft's tag to `untagged-…` when
    /// a PATCH leaves `tag_name` out (Visor 0.44's draft, 2026-11-05), and
    /// publishing it then would have made the wrong tag.
    static func editDraft(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let id = arguments.int("id")!
        var changes: [String: JSON] = [:]
        if let title = arguments.string("title") { changes["name"] = .string(title) }
        if let body = arguments.string("body") { changes["body"] = .string(body) }
        if let target = arguments.string("target") {
            guard Refs.isValid(target) else { throw ToolError.invalid("target is a branch or commit SHA: \(target)") }
            changes["target_commitish"] = .string(target)
        }
        guard !changes.isEmpty else { throw ToolError.invalid("release_edit_draft changes a title, body or target: give one") }
        let current = try await context.github.json(repo, "GET", "/repos/\(repo)/releases/\(id)")
        guard current["draft"]?.boolValue == true else {
            let tag = current["tag_name"]?.stringValue ?? "?"
            throw ToolError.refused("release \(id) (\(tag)) is published; gh_mcp edits drafts only")
        }
        if let tag = current["tag_name"]?.stringValue, !tag.isEmpty { changes["tag_name"] = .string(tag) }
        let release = try await context.github.json(repo, "PATCH", "/repos/\(repo)/releases/\(id)", body: .object(changes))
        return pick(release, fields).text()
    }

    static func list(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let releases = try await context.github.json(repo, "GET", "/repos/\(repo)/releases", query: ["per_page": "30"])
        return JSON.array((releases.arrayValue ?? []).map { pick($0, fields) }).text()
    }

    static let maxFile = 512 << 10

    static func file(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let path = arguments.string("path")!
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw ToolError.invalid("path is a path in the repository, like docs/README.md: \(path)")
        }
        var query: [String: String] = [:]
        if let ref = arguments.string("ref") {
            guard Refs.isReadableRef(ref) else { throw ToolError.invalid("ref is a branch, tag or commit SHA: \(ref)") }
            query["ref"] = ref
        }
        let encoded = components.map { encodeSegment(String($0)) }.joined(separator: "/")
        let apiPath = "/repos/\(repo)/contents/\(encoded)"
        let response = try await context.github.send(repo, "GET", apiPath, query: query, accept: "application/vnd.github.raw")
        guard response.isSuccess else {
            if response.status == 404 {
                throw ToolError.failed("\(repo) has no \(path)\(query["ref"].map { " at \($0)" } ?? "")")
            }
            throw ToolError.failed(GitHub.describe(response, method: "GET", path: apiPath))
        }
        // A folder comes back as JSON (raw is for files only).
        if (response.headers["content-type"] ?? "").hasPrefix("application/json"), let entries = try? JSON.parse(response.body).arrayValue {
            let lines = entries.map { entry in
                let name = entry["name"]?.stringValue ?? "?"
                return entry["type"]?.stringValue == "dir" ? name + "/" : name
            }
            return "\(path)/ in \(repo):\n" + lines.joined(separator: "\n")
        }
        let data = response.body
        if data.prefix(8000).contains(0) || String(data: data, encoding: .utf8) == nil {
            return "\(path) is binary (\(data.count) bytes); not shown."
        }
        if data.count > maxFile {
            return String(decoding: data.prefix(maxFile), as: UTF8.self) + "\n… (\(data.count) bytes; the first \(maxFile) shown)"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

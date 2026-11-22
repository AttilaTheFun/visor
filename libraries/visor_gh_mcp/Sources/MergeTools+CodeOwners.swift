import Foundation

extension MergeTools {
    /// nil if the pull request touches nothing CODEOWNERS owns (or owners
    /// approved its head), else why not. CODEOWNERS is read from the base
    /// branch, as GitHub reads it: a pull request can't loosen its own.
    static func ownersRefusal(_ repo: RepoName, number: Int, base: String, head: String, _ context: ToolContext) async throws -> String? {
        guard let owners = try await codeOwners(repo, ref: base, context) else { return nil }

        // The files it changes, with a rename's old name too.
        var touched: [String] = []
        var page = 1
        while true {
            let answer = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)/files",
                                                       query: ["per_page": "100", "page": String(page)])
            let files = answer.arrayValue ?? []
            for file in files {
                if let name = file["filename"]?.stringValue { touched.append(name) }
                if let old = file["previous_filename"]?.stringValue { touched.append(old) }
            }
            if files.count < 100 { break }
            page += 1
            // GitHub lists 3000 files at most: a bigger change can't be checked.
            if page > 30 { return "it changes more than 3000 files, too many to check against CODEOWNERS" }
        }
        var owned: [(path: String, owners: [String])] = []
        for path in touched {
            let names = owners.owners(of: path)
            if !names.isEmpty { owned.append((path, names)) }
        }
        guard !owned.isEmpty else { return nil }

        // An owner's approval of this very head (their latest review, so a
        // later request for changes or a dismissal counts). Only people's
        // approvals are read; a team or an email can't be checked here.
        var latest: [String: (state: String, commit: String)] = [:]
        page = 1
        while true {
            let answer = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)/reviews",
                                                       query: ["per_page": "100", "page": String(page)])
            let reviews = answer.arrayValue ?? []
            for review in reviews {
                guard let login = review["user"]?["login"]?.stringValue?.lowercased(),
                      let state = review["state"]?.stringValue, state != "COMMENTED", state != "PENDING" else { continue }
                latest[login] = (state, review["commit_id"]?.stringValue ?? "")
            }
            if reviews.count < 100 || page >= 10 { break }
            page += 1
        }
        let unapproved = owned.filter { file in
            !file.owners.contains { owner in
                guard owner.hasPrefix("@"), !owner.contains("/") else { return false }
                let login = String(owner.dropFirst()).lowercased()
                guard let review = latest[login] else { return false }
                return review.state == "APPROVED" && review.commit == head
            }
        }
        guard !unapproved.isEmpty else { return nil }
        let names = Array(Set(unapproved.flatMap(\.owners))).sorted().joined(separator: ", ")
        let paths = unapproved.prefix(5).map(\.path).joined(separator: ", ") + (unapproved.count > 5 ? " and \(unapproved.count - 5) more" : "")
        return "it changes protected files (\(paths)) and \(names) hasn't approved its head: those need their review"
    }

    /// The base branch's CODEOWNERS, from GitHub's first place that has
    /// one; nil if none does.
    static func codeOwners(_ repo: RepoName, ref: String, _ context: ToolContext) async throws -> CodeOwners? {
        for path in CodeOwners.paths {
            let api = "/repos/\(repo)/contents/\(path)"
            let response = try await context.github.send(repo, "GET", api, query: ["ref": ref])
            if response.status == 404 { continue }
            guard response.isSuccess, let answer = try? JSON.parse(response.body),
                  let content = answer["content"]?.stringValue,
                  let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")),
                  let text = String(data: data, encoding: .utf8) else {
                // Unreadable: refuse rather than guess the file says nothing.
                throw ToolError.failed("\(repo)'s \(path) can't be read: \(GitHub.describe(response, method: "GET", path: api))")
            }
            return CodeOwners(text)
        }
        return nil
    }
}

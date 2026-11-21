// gh_mcp's rules, as they came: the repositories and branches it takes, what it
// redacts, the arguments it checks, releases drafts only.

import Foundation
import Testing
@testable import VisorGHMCP

// MARK: Rules

@Test func repositoryRules() throws {
    let rules = RepoRules(["AttilaTheFun/*", "other/one"])
    #expect(try rules.check("attilathefun/oss").description == "attilathefun/oss")
    #expect(rules.allows(RepoName("Other/One")!))
    #expect(!rules.allows(RepoName("other/two")!))
    #expect(throws: ToolError.self) { try rules.check("someone/else") }
    #expect(throws: ToolError.self) { try rules.check("not a repo") }
    #expect(RepoName(remoteURL: "https://github.com/AttilaTheFun/oss.git")?.description == "AttilaTheFun/oss")
    #expect(RepoName(remoteURL: "git@github.com:AttilaTheFun/oss.git")?.description == "AttilaTheFun/oss")
    #expect(RepoName(remoteURL: "ssh://git@github.com/AttilaTheFun/oss")?.description == "AttilaTheFun/oss")
    #expect(RepoName(remoteURL: "https://x-access-token:abc@github.com/AttilaTheFun/oss/")?.description == "AttilaTheFun/oss")
    #expect(RepoName(remoteURL: "https://gitlab.com/AttilaTheFun/oss.git") == nil)
    #expect(RepoName(remoteURL: "/tmp/bare.git") == nil)
}

@Test func branchRules() throws {
    #expect(try Refs.pushableBranch("feature/x") == "feature/x")
    #expect(try Refs.pushableBranch("refs/heads/fix") == "fix")
    for refused in ["main", "master", "Main", "refs/heads/main", "refs/tags/v1.0", "refs/remotes/origin/x"] {
        #expect(throws: ToolError.self) { try Refs.pushableBranch(refused) }
    }
    for invalid in ["a..b", "-x", "x.lock", "a b", "x:y", "HEAD", "", "a/", ".hidden"] {
        #expect(throws: ToolError.self) { try Refs.pushableBranch(invalid) }
    }
}

@Test func redaction() {
    #expect(Redact.secrets(in: "token ghs_abcdefghijklmnop done") == "token ghs_[redacted] done")
    #expect(Redact.secrets(in: "key ghmcp_AbCdEf123456-_x") == "key ghmcp_[redacted]")
    #expect(!CallLog.line(time: Date(), caller: "s@a", tool: "pr_list", repo: "o/r", outcome: "failed: ghs_abcdefghijkl\nbody").contains("ghs_abc"))
}

// MARK: Tools

@Test func argumentsAreChecked() async {
    let transport = FakeTransport()
    let server = makeServer(transport: transport)
    #expect(await call(server, "pr_view", ["repo": "AttilaTheFun/oss"]).text.contains("needs number"))
    #expect(await call(server, "pr_view", ["repo": "AttilaTheFun/oss", "number": 1, "merge": true]).text.contains("no argument merge"))
    #expect(await call(server, "pr_list", ["repo": "AttilaTheFun/oss", "state": "merged"]).text.hasPrefix("Invalid"))
    #expect(await call(server, "runs", ["repo": "AttilaTheFun/oss", "limit": 500]).text.hasPrefix("Invalid"))
    #expect(await call(server, "pr_list", ["repo": "someone/else"]).text.hasPrefix("Refused"))
    #expect(await call(server, "pr_edit", ["repo": "AttilaTheFun/oss", "number": "3"]).text.contains("give one"))
    #expect(await call(server, "repo_file", ["repo": "AttilaTheFun/oss", "path": "../etc/passwd"]).text.hasPrefix("Invalid"))
    #expect(transport.requests.isEmpty)
}

@Test func releasesAreDraftsOnly() async {
    let transport = FakeTransport([
        "POST /repos/AttilaTheFun/oss/releases": (201, ["id": 7, "tag_name": "v1", "draft": true]),
        "GET /repos/AttilaTheFun/oss/releases/8": (200, ["id": 8, "tag_name": "v0.9", "draft": false]),
        "GET /repos/AttilaTheFun/oss/releases/9": (200, ["id": 9, "tag_name": "v1.1", "draft": true]),
        "PATCH /repos/AttilaTheFun/oss/releases/9": (200, ["id": 9, "tag_name": "v1.1", "draft": true]),
    ])
    let server = makeServer(transport: transport)
    let drafted = await call(server, "release_draft", ["repo": "AttilaTheFun/oss", "tag": "v1", "target": "main", "title": "One", "body": ""])
    #expect(!drafted.isError)
    #expect(transport.requests.first?.body?["draft"] == true)
    let edited = await call(server, "release_edit_draft", ["repo": "AttilaTheFun/oss", "id": 8, "title": "x"])
    #expect(edited.isError && edited.text.contains("published"))
    #expect(!transport.requests.contains { $0.method == "PATCH" })
    // A draft's edit sends its own tag back: GitHub resets one a PATCH leaves out.
    let notes = await call(server, "release_edit_draft", ["repo": "AttilaTheFun/oss", "id": 9, "body": "notes"])
    #expect(!notes.isError)
    let patch = transport.requests.first { $0.method == "PATCH" }
    #expect(patch?.body?["tag_name"] == "v1.1")
    #expect(patch?.body?["body"] == "notes")
    #expect(patch?.body?["draft"] == nil)
}

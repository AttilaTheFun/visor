// git_push and git_fetch against local bare repositories, as they came:
// refusals, no hooks, no stored token, leases.

import Foundation
import Testing
@testable import VisorGHMCP

// MARK: git_push

@Test func pushRefusesMainTagsAndOtherRepos() async throws {
    let folder = temporaryFolder()
    let checkout = folder + "/checkout"
    try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
    try sh(["git", "init", "-q", "-b", "main"], in: checkout)
    try sh(["git", "commit", "-q", "--allow-empty", "-m", "one"], in: checkout)
    try sh(["git", "tag", "v1"], in: checkout)
    try sh(["git", "branch", "develop"], in: checkout)
    try sh(["git", "remote", "add", "origin", "https://github.com/AttilaTheFun/x.git"], in: checkout)
    let transport = FakeTransport(["GET /repos/AttilaTheFun/x": (200, ["default_branch": "develop"])])
    let server = makeServer(transport: transport)
    for branch in ["main", "master", "refs/tags/v1", "v1", "develop"] {
        let result = await call(server, "git_push", ["path": .string(checkout), "branch": .string(branch)])
        #expect(result.isError && result.text.hasPrefix("Refused"), "\(branch): \(result.text)")
    }
    try sh(["git", "checkout", "-q", "-b", "feature"], in: checkout)
    try sh(["git", "remote", "set-url", "origin", "https://github.com/someone/else.git"], in: checkout)
    #expect(await call(server, "git_push", ["path": .string(checkout), "branch": "feature"]).text.contains("not among"))
    try sh(["git", "remote", "set-url", "origin", folder + "/bare.git"], in: checkout)
    #expect(await call(server, "git_push", ["path": .string(checkout), "branch": "feature"]).text.contains("not a GitHub repository"))
}

@Test func pushSendsTheBranchWithoutHooksOrStoredToken() async throws {
    let folder = temporaryFolder()
    let bare = folder + "/remote.git", checkout = folder + "/checkout"
    try sh(["git", "init", "-q", "--bare", bare], in: folder)
    try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
    try sh(["git", "init", "-q", "-b", "main"], in: checkout)
    try sh(["git", "commit", "-q", "--allow-empty", "-m", "one"], in: checkout)
    try sh(["git", "checkout", "-q", "-b", "feature"], in: checkout)
    try sh(["git", "commit", "-q", "--allow-empty", "-m", "two"], in: checkout)
    try sh(["git", "remote", "add", "origin", "https://github.com/AttilaTheFun/x.git"], in: checkout)
    let hook = checkout + "/.git/hooks/pre-push"
    try "#!/bin/sh\ntouch \(folder)/hook-ran\n".write(toFile: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
    let transport = FakeTransport(["GET /repos/AttilaTheFun/x": (200, ["default_branch": "main"])])
    let server = makeServer(transport: transport, remoteURL: { _ in "file://" + bare })

    let pushed = await call(server, "git_push", ["path": .string(checkout), "branch": "feature"])
    #expect(!pushed.isError, "\(pushed.text)")
    let head = try sh(["git", "rev-parse", "feature"], in: checkout)
    #expect(try sh(["git", "rev-parse", "refs/heads/feature"], in: bare) == head)
    #expect(try sh(["git", "rev-parse", "refs/remotes/origin/feature"], in: checkout) == head)
    #expect(!FileManager.default.fileExists(atPath: folder + "/hook-ran"))
    let config = try String(contentsOfFile: checkout + "/.git/config", encoding: .utf8)
    #expect(!config.contains("ghs_") && !config.contains("credential"))

    // Rewritten history: refused without a lease, replaced with one.
    try sh(["git", "commit", "-q", "--amend", "--allow-empty", "-m", "two again"], in: checkout)
    let refused = await call(server, "git_push", ["path": .string(checkout), "branch": "feature"])
    #expect(refused.isError && refused.text.contains("refused"), "\(refused.text)")
    let forced = await call(server, "git_push", ["path": .string(checkout), "branch": "feature", "force_with_lease": true])
    #expect(!forced.isError && forced.text.contains("forced"), "\(forced.text)")
    #expect(try sh(["git", "rev-parse", "refs/heads/feature"], in: bare) == sh(["git", "rev-parse", "feature"], in: checkout))
}

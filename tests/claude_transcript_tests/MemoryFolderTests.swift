// Where Claude Code keeps a project's memory (ClaudeSessionFiles+Memory):
// under the project of the top of the main checkout of the repository a
// folder is in (a folder of it, a worktree of it), else of the folder; and
// a conversation's memory found beside its transcript first, a link to it
// followed, then under those projects.

import ClaudeTranscript
import Foundation
import Testing

@Suite final class MemoryFolderTests {
    private let root: URL
    private let home: URL

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("memory-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))), isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func key(_ url: URL) -> String { ClaudeSessionFiles.projectDirectoryName(for: url.path) }

    @Test func aFolderOfARepositoryHasItsTopsProject() throws {
        let top = try folder("app")
        _ = try folder("app/.git")
        let inside = try folder("app/Sources/App")
        #expect(ClaudeSessionFiles.memoryProjectDirectoryName(for: inside.path) == key(top))
        #expect(ClaudeSessionFiles.memoryProjectDirectoryName(for: top.path) == key(top))
    }

    @Test func aWorktreeHasItsMainCheckoutsProject() throws {
        let top = try folder("app")
        let worktreeGit = try folder("app/.git/worktrees/feature")
        try Data("../..\n".utf8).write(to: worktreeGit.appendingPathComponent("commondir"))
        let worktree = try folder("app-feature")
        try Data("gitdir: \(worktreeGit.path)\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        #expect(ClaudeSessionFiles.memoryProjectDirectoryName(for: worktree.path) == key(top))
    }

    @Test func aSubmoduleAndAFolderOutsideOneHaveTheirOwn() throws {
        let module = try folder("app/vendor/lib")
        _ = try folder("app/.git/modules/lib")
        try Data("gitdir: ../../.git/modules/lib\n".utf8).write(to: module.appendingPathComponent(".git"))
        #expect(ClaudeSessionFiles.memoryProjectDirectoryName(for: module.path) == key(module))
        let plain = try folder("plain/folder")
        #expect(ClaudeSessionFiles.memoryProjectDirectoryName(for: plain.path) == key(plain))
    }

    @Test func theMemoryBesideTheTranscriptComesFirstALinkFollowed() throws {
        let projects = ClaudeSessionFiles.projectsRoot(home: home)
        let cwd = try folder("work")
        let kept = projects.appendingPathComponent("-elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let transcript = kept.appendingPathComponent("c.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        // None anywhere: nil.
        #expect(ClaudeSessionFiles.memoryFolder(conversation: transcript, cwd: cwd.path, home: home) == nil)
        // The folder's own project's.
        let own = projects.appendingPathComponent(key(cwd) + "/memory", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("own".utf8).write(to: own.appendingPathComponent("MEMORY.md"))
        #expect(ClaudeSessionFiles.memoryFolder(conversation: transcript, cwd: cwd.path, home: home)?.path == own.path)
        // An empty folder beside the transcript is passed over; a link there
        // to one with something in it is followed, before the folder's.
        let beside = kept.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        #expect(ClaudeSessionFiles.memoryFolder(conversation: transcript, cwd: cwd.path, home: home)?.path == own.path)
        try FileManager.default.removeItem(at: beside)
        let target = projects.appendingPathComponent("-shared/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("linked".utf8).write(to: target.appendingPathComponent("MEMORY.md"))
        try FileManager.default.createSymbolicLink(at: beside, withDestinationURL: target)
        #expect(ClaudeSessionFiles.memoryFolder(conversation: transcript, cwd: cwd.path, home: home)?.path == target.path)
    }

    /// A link out of Claude's projects folder (NCH, #562: a container's
    /// agent writes its Claude folder) is passed over, said, and never read.
    @Test func aMemoryLinkedOutOfTheProjectsFolderIsRefused() throws {
        let projects = ClaudeSessionFiles.projectsRoot(home: home)
        let cwd = try folder("work")
        let kept = projects.appendingPathComponent(key(cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let transcript = kept.appendingPathComponent("c.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let keys = try folder("home/.ssh")
        try Data("a secret key".utf8).write(to: keys.appendingPathComponent("id_ed25519"))
        try FileManager.default.createSymbolicLink(at: kept.appendingPathComponent("memory"), withDestinationURL: keys)
        var said: [String] = []
        #expect(ClaudeSessionFiles.memoryFolder(conversation: transcript, cwd: cwd.path, home: home, refused: { said.append($0) }) == nil)
        #expect(said.count == 1 && said.allSatisfy { $0.contains("leads out of") && !$0.contains("a secret key") }, "\(said)")
        // The projects folder's own link to itself, or a sibling's name that
        // starts with its own, is no way in either.
        #expect(!ClaudeSessionFiles.isInsideProjects(projects.path, home: home))
        #expect(!ClaudeSessionFiles.isInsideProjects(projects.path + "-else/memory", home: home))
        #expect(ClaudeSessionFiles.isInsideProjects(projects.path + "/-x/memory", home: home))
    }
}

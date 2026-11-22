import Foundation

/// artifact_download: a run's artifact, unzipped into a new folder in a
/// checkout of an allowed repository, or under /tmp.
enum ArtifactTool {
    static let maxSize = 2 << 30

    static func run(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let runID = arguments.int("run_id")!
        let name = arguments.string("name")!
        let destination = try await destination(arguments.string("path")!, context: context)
        let artifactsPath = "/repos/\(repo)/actions/runs/\(runID)/artifacts"
        let list = try await context.github.json(repo, "GET", artifactsPath, query: ["name": name, "per_page": "100"])
        guard let artifact = (list["artifacts"]?.arrayValue ?? []).first(where: { $0["name"]?.stringValue == name }) else {
            let all = try? await context.github.json(repo, "GET", artifactsPath, query: ["per_page": "100"])
            let names = (all?["artifacts"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            throw ToolError.failed("run \(runID) has no artifact \(name) (its artifacts: \(names.isEmpty ? "none" : names.joined(separator: ", ")))")
        }
        if artifact["expired"]?.boolValue == true { throw ToolError.failed("artifact \(name) of run \(runID) has expired") }
        guard let id = artifact["id"]?.intValue else { throw ToolError.failed("GitHub gave artifact \(name) no id") }
        if let size = artifact["size_in_bytes"]?.intValue, size > maxSize {
            throw ToolError.refused("artifact \(name) is \(size) bytes; gh_mcp downloads at most \(maxSize)")
        }
        let zipPath = "/repos/\(repo)/actions/artifacts/\(id)/zip"
        let response = try await context.github.send(repo, "GET", zipPath)
        guard response.isRedirect, let location = response.location else {
            throw ToolError.failed(GitHub.describe(response, method: "GET", path: zipPath))
        }
        let scratch = context.services.scratch + "/gh_mcp-artifact-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let zip = scratch + "/artifact.zip"
        try await context.services.transport.download(location, to: zip)
        let (files, bytes) = try await Unzip.extract(zip, into: destination, scratch: scratch + "/out",
                                                     unzip: context.services.unzip, git: context.services.git)
        return "Unzipped artifact \(name) of run \(runID) into \(destination): \(files) files, \(bytes) bytes."
    }

    /// Where an artifact may go: an absolute path, no `..`, no .git, that
    /// does not exist yet or is an empty folder, whose nearest existing
    /// folder (symbolic links resolved) is in a temporary root or in a
    /// checkout with a remote that is an allowed repository.
    static func destination(_ path: String, context: ToolContext) async throws -> String {
        guard path.hasPrefix("/") else { throw ToolError.invalid("path is absolute") }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { throw ToolError.invalid("path has no . or .. in it: \(path)") }
        guard !components.contains(".git") else { throw ToolError.refused("artifacts never go into a .git folder") }
        let files = FileManager.default
        var existing = "/" + components.joined(separator: "/")
        var missing: [String] = []
        while !files.fileExists(atPath: existing) {
            missing.insert(URL(fileURLWithPath: existing).lastPathComponent, at: 0)
            existing = URL(fileURLWithPath: existing).deletingLastPathComponent().path
        }
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: existing, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError.invalid("\(existing) is not a folder")
        }
        if missing.isEmpty, !((try? files.contentsOfDirectory(atPath: existing)) ?? []).isEmpty {
            throw ToolError.refused("\(path) is not empty; name a folder that does not exist yet")
        }
        guard let real = realPath(existing) else { throw ToolError.failed("\(existing) could not be resolved") }
        let final = ([real == "/" ? "" : real] + missing).joined(separator: "/")
        guard !final.split(separator: "/").contains(".git") else { throw ToolError.refused("artifacts never go into a .git folder") }
        for root in context.services.temporaryRoots {
            if let root = realPath(root), real == root || real.hasPrefix(root + "/") { return final }
        }
        let git = context.services.git
        guard let top = try await git.value(["rev-parse", "--show-toplevel"], in: real), let realTop = realPath(top),
              real == realTop || real.hasPrefix(realTop + "/") else {
            throw ToolError.refused("\(path) is not in a checkout of an allowed repository, nor under /tmp")
        }
        let remotes = try await git.run(["config", "--get-regexp", #"^remote\..*\.url$"#], in: realTop)
        let repos = remotes.output.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(separator: " ").last.flatMap { RepoName(remoteURL: String($0)) }
        }
        guard repos.contains(where: context.rules.allows) else {
            throw ToolError.refused("\(realTop) is not a checkout of an allowed repository")
        }
        return final
    }
}

// A session moved to this runner, made ready before its harness starts
// (Job.resume_session_id): its conversation fetched from its driver
// (AgentDriver.Conversation) into the harness's own folder, so `claude
// --resume` finds it, and the repositories it worked in cloned where the
// runner keeps sources. Nothing already there is overwritten: a file the
// harness already has, or a repository already cloned, is left as it is.

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public enum ResumePreparation {
    public enum Problem: Error, CustomStringConvertible {
        case badDriver(String)
        case badPlace(String)
        case cloneFailed(String, Int32)

        public var description: String {
            switch self {
            case .badDriver(let url): "the driver isn't http://host:port: \(url)"
            case .badPlace(let place): "a conversation file's place leaves the harness's folder: \(place)"
            case .cloneFailed(let repository, let status): "git clone \(repository) ended with \(status)"
            }
        }
    }

    /// Claude Code's own folder: $CLAUDE_CONFIG_DIR when set, else ~/.claude.
    public static func claudeFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let set = environment["CLAUDE_CONFIG_DIR"], !set.isEmpty { return URL(fileURLWithPath: set, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The conversation of `agent`, for a harness working in
    /// `workingDirectory`, from the driver at `driverURL` into `folder`.
    /// Answers how many files were written (0: the driver had none, or all
    /// were there already).
    public static func fetchConversation(driverURL: String, agent: AgentProtocol_V1_AgentID, workingDirectory: String,
                                         harness: String, into folder: URL) async throws -> Int {
        guard let components = URLComponents(string: driverURL), components.scheme == "http",
              let host = components.host, !host.isEmpty else { throw Problem.badDriver(driverURL) }
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: host, port: components.port ?? 80), transportSecurity: .plaintext)
        let request = AgentProtocol_V1_ConversationRequest.with {
            $0.agent = agent
            $0.workingDirectory = workingDirectory
            $0.harness = harness
        }
        return try await withGRPCClient(transport: transport) { client in
            let driver = AgentProtocol_V1_AgentDriver.Client(wrapping: client)
            return try await driver.conversation(request) { response in
                var writer = ConversationWriter(folder: folder)
                for try await piece in response.messages { try writer.take(piece) }
                return writer.written
            }
        }
    }

    /// Each of `sources` cloned under `directory` by its name, at its ref,
    /// with `git`: one already there is left as it is. Answers the folders
    /// cloned.
    public static func clone(_ sources: [AgentProtocol_V1_Source], into directory: String,
                             git: (_ arguments: [String]) throws -> Int32 = Self.runGit) throws -> [String] {
        var cloned: [String] = []
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for source in sources where !source.repository.isEmpty {
            let name = source.name.isEmpty ? Self.name(of: source.repository) : source.name
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { continue }
            let target = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target) { continue }
            var arguments = ["clone", "--quiet"]
            if !source.ref.isEmpty { arguments += ["--branch", source.ref] }
            arguments += [source.repository, target]
            let status = try git(arguments)
            guard status == 0 else { throw Problem.cloneFailed(source.repository, status) }
            cloned.append(target)
        }
        return cloned
    }

    /// A repository's folder name from its URL: `visor` of
    /// `https://github.com/AttilaTheFun/visor.git`.
    static func name(of repository: String) -> String {
        var last = (repository as NSString).lastPathComponent
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last
    }

    /// `git` with these arguments, its output the wrapper's, to its end.
    public static func runGit(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// The conversation's pieces written under the harness's folder: a file is
/// written once its last piece has come, and only where nothing is.
struct ConversationWriter {
    let folder: URL
    private(set) var written = 0
    private var pending: [String: Data] = [:]

    init(folder: URL) {
        self.folder = folder
    }

    mutating func take(_ piece: AgentProtocol_V1_ConversationFile) throws {
        let place = piece.place
        guard !place.isEmpty, !place.hasPrefix("/"), !place.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw ResumePreparation.Problem.badPlace(place)
        }
        pending[place, default: Data()].append(piece.data)
        guard piece.last, let data = pending.removeValue(forKey: place) else { return }
        let file = folder.appendingPathComponent(place, isDirectory: false)
        if FileManager.default.fileExists(atPath: file.path) { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        written += 1
    }
}

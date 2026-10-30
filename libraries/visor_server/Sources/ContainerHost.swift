// A container host (docs/container-host.md): the program this server runs
// sessions' containers through — the one set in its settings, else
// `visor-container-host` on the PATH — spoken to on its command line, JSON
// in and out. An agent in a container is the host's `exec` of it, run and
// kept by the agent's host like any agent.

import Foundation
import VisorProtocol

struct ContainerHost: ContainerExecuting, Equatable {
    /// The contract's version this server speaks.
    static let api = 1
    /// The name a host on the PATH goes by.
    static let defaultName = "visor-container-host"
    /// The program, and the arguments before each operation.
    let command: ShellCommand

    /// The host to use: the one set, else `visor-container-host` on the
    /// PATH; nil when there is none, and sessions run on this computer only.
    static func found(setting: ShellCommand?, onPath: (String) -> String? = { ToolPath.resolve($0) }) -> ContainerHost? {
        if let setting, !setting.executable.isEmpty { return ContainerHost(command: setting) }
        return onPath(defaultName).map { ContainerHost(command: ShellCommand($0)) }
    }

    /// `health`: whether it can make containers now.
    struct Health: Equatable, Sendable {
        var ok: Bool
        var name: String
        var version: String
        var error: String?
        var limits: Limits?
    }

    /// The most a container of the host's may have: the computer's own,
    /// for a host with no limits of its own; nil for what it doesn't say.
    struct Limits: Equatable, Sendable {
        var cpus: Int?
        var memoryBytes: Int64?
    }

    /// A container `create` made.
    struct Made: Equatable, Sendable {
        var id: String
        var name: String
    }

    /// One of the containers `ls` lists.
    struct Listed: Equatable, Sendable {
        var id: String
        var name: String
        var labels: [String: String]
    }

    /// `network`: whether a container's network works.
    struct Network: Equatable, Sendable {
        var ok: Bool
        var detail: String
    }

    func health() async -> Health {
        do {
            let answer = try await json(["health"])
            let limits = answer["limits"].object.map { _ in Limits(cpus: answer["limits"]["cpus"].int, memoryBytes: answer["limits"]["memoryBytes"].int64) }
            return Health(ok: answer["ok"].bool ?? false, name: answer["name"].string ?? command.executable,
                          version: answer["version"].string ?? "", error: answer["error"].string, limits: limits)
        } catch {
            return Health(ok: false, name: command.executable, version: "", error: "\(error)")
        }
    }

    func create(_ request: ContainerHostRequest) async throws -> Made {
        let answer = try await json(["create"], input: try JSONEncoder().encode(request))
        guard let id = answer["id"].string, !id.isEmpty else { throw ContainerHostError(message: "The container host made no container.") }
        return Made(id: id, name: answer["name"].string ?? request.name)
    }

    func put(_ data: Data, at path: String, mode: String = "600", in container: String) async throws {
        _ = try await json(["put", container, path, "--mode=" + mode], input: data)
    }

    func remove(_ container: String, volumes: Bool) async throws {
        _ = try await json(["rm", container] + (volumes ? ["--volumes"] : []))
    }

    func list() async throws -> [Listed] {
        try await json(["ls"])["containers"].array?.compactMap { item in
            guard let id = item["id"].string else { return nil }
            return Listed(id: id, name: item["name"].string ?? "", labels: item["labels"].object?.compactMapValues(\.string) ?? [:])
        } ?? []
    }

    func network(_ container: String) async throws -> Network {
        let answer = try await json(["network", container])
        return Network(ok: answer["ok"].bool ?? false, detail: answer["detail"].string ?? "")
    }

    func execute(container: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String) {
        guard let ran = await run(["exec", container, "--"] + command, input: input ?? Data(), errors: true) else {
            throw ContainerHostError(message: "The container host \(self.command.executable) couldn't be started.")
        }
        return (ran.status, ran.text)
    }

    func command(container: String, executable: String, arguments: [String], directory: String, environmentFile: String) -> ShellCommand {
        ShellCommand(command.executable, command.arguments + ["exec", container, "--interactive", "--workdir=" + directory,
                                                              "--env-file=" + environmentFile, "--", executable] + arguments)
    }

    private func run(_ operation: [String], input: Data?, errors: Bool = false) async -> (status: Int32, text: String)? {
        await Command.output(command.executable, command.arguments + operation, environment: ToolPath.environment(), errors: errors, input: input)
    }

    /// An operation's answer: its JSON, or what went wrong, thrown.
    private func json(_ operation: [String], input: Data? = nil) async throws -> JSONValue {
        guard let ran = await run(operation, input: input) else {
            throw ContainerHostError(message: "The container host \(command.executable) couldn't be started.")
        }
        let answer = parseJSON(ran.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .null
        guard ran.status == 0 else {
            let said = ran.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ContainerHostError(message: answer["error"].string ?? (said.isEmpty ? "The container host failed (\(ran.status))." : said),
                                     code: answer["code"].string)
        }
        return answer
    }
}

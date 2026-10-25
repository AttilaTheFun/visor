import Foundation
import Synchronization
import VisorServer

/// A Mac's containers: Apple's container (github.com/apple/container), each
/// a Linux machine of its own, driven through its command-line tool.
public struct AppleContainers: ContainerRunning {
    /// The tool: where Apple's installer puts it, else where Homebrew does,
    /// else the first on the path.
    let tool: String

    public init(tool: String? = nil) {
        self.tool = tool ?? Self.locate() ?? "/usr/local/bin/container"
    }

    static func locate(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        let places = ["/usr/local/bin", "/opt/homebrew/bin"] + path.split(separator: ":").map(String.init)
        return places.map { $0 + "/container" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func problem() async -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            return "Apple's container is not installed (github.com/apple/container, or `brew install container`)"
        }
        guard let status = try? await Self.run(tool, ["system", "status"]), status.status == 0 else {
            return "Apple's container is not started (`container system start`)"
        }
        return nil
    }

    public func run(_ spec: ContainerSpec) async throws {
        var arguments = ["run", "--detach", "--name", spec.name]
        if let disk = spec.disk {
            let volume = Self.disk(of: spec.name)
            // One kept from before at another size goes: a volume is not
            // made larger or smaller.
            if let had = await diskSize(volume), had != disk { _ = try? await Self.run(tool, ["volume", "delete", volume]) }
            if await diskSize(volume) == nil {
                let made = try await Self.run(tool, ["volume", "create", "-s", "\(disk / 1_048_576)M", volume])
                guard made.status == 0 else { throw AppleContainersError(message: made.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            arguments += ["--volume", "\(volume):\(spec.diskTarget)"]
        }
        for mount in spec.mounts {
            arguments += ["--mount", "type=bind,source=\(mount.source),target=\(mount.target)" + (mount.readOnly ? ",readonly" : "")]
        }
        for (key, value) in spec.labels.sorted(by: { $0.key < $1.key }) { arguments += ["--label", "\(key)=\(value)"] }
        if let cpus = spec.cpus { arguments += ["--cpus", String(cpus)] }
        // x86_64 Linux programs run in it too, where the Mac has Rosetta
        // (Android's build tools come for x86_64 alone).
        if Self.hasRosetta { arguments += ["--rosetta"] }
        if let memory = spec.memory { arguments += ["--memory", "\(max(memory / 1_048_576, 512))M"] }
        arguments += [spec.image, "sleep", "infinity"]
        let made = try await Self.run(tool, arguments)
        guard made.status == 0 else { throw AppleContainersError(message: made.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func isRunning(_ name: String) async -> Bool? {
        guard let listed = try? await Self.run(tool, ["list", "--all", "--format", "json"]), listed.status == 0,
              let containers = try? JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [[String: Any]] else { return nil }
        guard let container = containers.first(where: { (($0["configuration"] as? [String: Any])?["id"] as? String) == name }) else { return nil }
        return (container["status"] as? String) == "running"
    }

    public func remove(_ name: String, keepingDisk: Bool) async throws {
        let removed = try await Self.run(tool, ["delete", "--force", name])
        guard removed.status == 0 else { throw AppleContainersError(message: removed.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if !keepingDisk, await diskSize(Self.disk(of: name)) != nil { _ = try? await Self.run(tool, ["volume", "delete", Self.disk(of: name)]) }
    }

    /// The name of a container's disk of its own.
    static func disk(of container: String) -> String { container + "-build" }

    /// A volume's size in bytes; nil when there is no such volume.
    private func diskSize(_ volume: String) async -> UInt64? {
        guard let read = try? await Self.run(tool, ["volume", "inspect", volume]), read.status == 0,
              let volumes = try? JSONSerialization.jsonObject(with: Data(read.output.utf8)) as? [[String: Any]],
              let size = ((volumes.first?["configuration"] as? [String: Any])?["sizeInBytes"] as? NSNumber)?.uint64Value else { return nil }
        return size
    }

    /// `container stats` for the running ones (processor time and memory),
    /// with the cores each was given from `container list`.
    public func stats() async -> [ContainerStats] {
        guard let read = try? await Self.run(tool, ["stats", "--no-stream", "--format", "json"]), read.status == 0,
              let rows = try? JSONSerialization.jsonObject(with: Data(read.output.utf8)) as? [[String: Any]] else { return [] }
        var cores: [String: Int] = [:]
        if let listed = try? await Self.run(tool, ["list", "--format", "json"]), listed.status == 0,
           let containers = try? JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [[String: Any]] {
            for container in containers {
                let configuration = container["configuration"] as? [String: Any]
                if let id = configuration?["id"] as? String, let cpus = (configuration?["resources"] as? [String: Any])?["cpus"] as? Int {
                    cores[id] = cpus
                }
            }
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let used = (row["cpuUsageUsec"] as? NSNumber)?.uint64Value else { return nil }
            return ContainerStats(id: id, cpuMicroseconds: used, cpus: cores[id], memoryUsedBytes: (row["memoryUsageBytes"] as? NSNumber)?.uint64Value,
                                  memoryLimitBytes: (row["memoryLimitBytes"] as? NSNumber)?.uint64Value)
        }
    }

    public func execute(_ name: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String) {
        try await Self.run(tool, ["exec"] + (input == nil ? [] : ["--interactive"]) + [name] + command, input: input)
    }

    public func command(in name: String, executable: String, arguments: [String], directory: String,
                        environmentFile: String) -> ShellCommand {
        // Started again first if it was stopped (the Mac restarted, say);
        // then the agent in it, its standard input kept open, as the
        // host's own child.
        let script = """
            tool="$1"; name="$2"; folder="$3"; variables="$4"; shift 4
            "$tool" start "$name" >/dev/null 2>&1 || true
            exec "$tool" exec --interactive --workdir "$folder" --env-file "$variables" "$name" "$@"
            """
        return ShellCommand("/bin/sh", ["-c", script, "visor-container", tool, name, directory, environmentFile, executable] + arguments)
    }

    /// Rosetta is installed on this Mac.
    static var hasRosetta: Bool { FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") }

    /// Runs the tool to its end: its status, and what it wrote (standard
    /// output and error together).
    private static func run(_ tool: String, _ arguments: [String], input: Data? = nil) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            launch(tool, arguments, input: input) { continuation.resume(with: $0) }
        }
    }

    /// Outside any actor: the process ends on a queue of its own.
    private nonisolated static func launch(_ tool: String, _ arguments: [String], input: Data?,
                                           done: @escaping @Sendable (Result<(status: Int32, output: String), any Error>) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let feed = input.map { _ in Pipe() }
        process.standardInput = feed ?? FileHandle.nullDevice
        let collected = Collected()
        output.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        process.terminationHandler = { ended in
            output.fileHandleForReading.readabilityHandler = nil
            collected.append(output.fileHandleForReading.readDataToEndOfFile())
            done(.success((ended.terminationStatus, collected.text)))
        }
        do {
            try process.run()
        } catch {
            return done(.failure(error))
        }
        if let feed, let input {
            feed.fileHandleForWriting.write(input)
            try? feed.fileHandleForWriting.close()
        }
    }
}

/// What the tool wrote, gathered as it arrives on the pipe's own queue.
private final class Collected: Sendable {
    private let data = Mutex(Data())

    func append(_ chunk: Data) { data.withLock { $0.append(chunk) } }

    var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
}

/// What the tool said when it refused.
private struct AppleContainersError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

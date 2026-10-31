import Foundation
import Synchronization
import VisorRunner

/// The Runner's container backend, played here: containers and volumes kept
/// in memory (every container at 127.0.0.1), each request and command kept,
/// and `exec` run on this computer. A file written lands in `fs/`, the
/// network probe and the gateway are answered, the Runner's own files in
/// the container are this folder's, and anything else runs here with
/// `visor-server` a fake on the PATH (it keeps its password in `password`
/// and its port in `started`, its calls in `server-calls`).
final class FakeBackend: ContainerBackend {
    let folder: URL
    private let held = Mutex(Held())

    struct Held {
        var containers: [String: ContainerInfo] = [:]
        var volumes: Set<String> = []
        var requests: [ContainerRequest] = []
        var calls: [String] = []
        var networkLost = false
        var unavailable: String?
    }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)", isDirectory: true)
        for sub in ["", "fs", "bin"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let server = #"""
            #!/bin/bash
            dir="$(cd "$(dirname "$0")/.." && pwd)"
            echo "visor-server $*" >> "$dir/server-calls"
            case "$1" in
              password) echo "$2" > "$dir/password" ;;
              start) port=""; prev=""; for a in "$@"; do [ "$prev" = "--port" ] && port="$a"; prev="$a"; done
                # The test's own server (FakeVisorServer) takes it from here.
                echo "$port" > "$dir/started" ;;
            esac
            """#
        let path = folder.appendingPathComponent("bin/visor-server")
        try server.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    var requests: [ContainerRequest] { held.withLock { $0.requests } }
    var calls: [String] { held.withLock { $0.calls } }
    var volumes: Set<String> { held.withLock { $0.volumes } }
    var networkLost: Bool {
        get { held.withLock { $0.networkLost } }
        set { held.withLock { $0.networkLost = newValue } }
    }
    var unavailableBecause: String? {
        get { held.withLock { $0.unavailable } }
        set { held.withLock { $0.unavailable = newValue } }
    }

    var serverCalls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("server-calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A file the Runner wrote in the container, by its path there.
    func written(_ path: String) -> String? {
        try? String(contentsOf: fsFile(path), encoding: .utf8)
    }

    func fsFile(_ path: String) -> URL { folder.appendingPathComponent("fs").appendingPathComponent(path.replacingOccurrences(of: "/", with: "_")) }

    func unavailable() -> String? { unavailableBecause }

    func container(_ name: String) -> ContainerInfo? { held.withLock { $0.containers[name] } }

    func create(_ request: ContainerRequest) -> String? {
        held.withLock {
            $0.requests.append(request)
            $0.calls.append("create \(request.name)")
            for volume in request.volumes { $0.volumes.insert(volume.name) }
            $0.containers[request.name] = ContainerInfo(name: request.name, running: true, labels: request.labels, address: "127.0.0.1")
        }
        return nil
    }

    func start(_ name: String) -> String? {
        held.withLock {
            $0.calls.append("start \(name)")
            guard $0.containers[name] != nil else { return "no container \(name)" }
            $0.containers[name]?.running = true
            return nil
        }
    }

    func stop(_ name: String) -> String? {
        held.withLock {
            $0.calls.append("stop \(name)")
            guard $0.containers[name] != nil else { return "no container \(name)" }
            $0.containers[name]?.running = false
            return nil
        }
    }

    func remove(_ name: String, volumes: [String]) {
        held.withLock {
            $0.calls.append("remove \(name)" + (volumes.isEmpty ? "" : " " + volumes.joined(separator: " ")))
            $0.containers.removeValue(forKey: name)
            for volume in volumes { $0.volumes.remove(volume) }
        }
    }

    func exec(_ name: String, _ command: [String], input: Data?) -> ContainerExec? {
        let (running, lost) = held.withLock { ($0.containers[name]?.running == true, $0.networkLost) }
        guard running else { return nil }
        held.withLock { $0.calls.append(command.joined(separator: " ")) }
        if command.first == "rm" {
            for path in command.dropFirst(2) { try? FileManager.default.removeItem(at: fsFile(path)) }
            return ContainerExec(status: 0, output: "")
        }
        guard command.count >= 4, command[0] == "sh", command[1] == "-c" else { return ContainerExec(status: 127, output: "") }
        let script = command[2], arguments = Array(command.dropFirst(4))
        if script.contains("cat > \"$1\""), let path = arguments.first {
            return (try? (input ?? Data()).write(to: fsFile(path))) == nil ? ContainerExec(status: 1, output: "") : ContainerExec(status: 0, output: "")
        }
        if script.contains("getent hosts") { return ContainerExec(status: 0, output: lost ? "" : "dns\nreach\n") }
        if script.contains("/proc/net/route") { return ContainerExec(status: 0, output: "0140A8C0\n") }
        // The Runner's own files in the container are this folder's.
        let local = script.replacingOccurrences(of: "/root/.visor-runner/", with: folder.path + "/fs/_root_.visor-runner_")
        return Self.run(["/bin/sh", "-c", local, "sh"] + arguments, input: input, path: folder.appendingPathComponent("bin").path)
    }

    /// A program run here to its end, `bin` first on its PATH.
    static func run(_ arguments: [String], input: Data?, path: String) -> ContainerExec? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let feed = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : feed
        do { try process.run() } catch { return nil }
        if let input {
            try? feed.fileHandleForWriting.write(contentsOf: input)
            try? feed.fileHandleForWriting.close()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ContainerExec(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}

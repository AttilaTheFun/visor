// A command run to its end in the Sessions container (VisorServer's
// ContainerCommand: Super Compact's `claude -p` and the models'
// `initialize`, when the container is on): `sh -c 'exec "$@" < <input>'`,
// its standard input a file on Sessions (`.visor-commands/<id>.in`, this
// user's alone, gone once it ends), its output the process's log on the
// Visor volume, read while it runs (for `answered`) and once it ends; ended
// by a KILL when it's stopped, out of time, or answered.

import Foundation
import Synchronization
import VisorContainerCore
import VisorServer

extension ContainerEngine {
    /// How often a running command is looked at.
    static let commandPoll: Duration = .milliseconds(200)

    /// `command` run to its end in the container (started first if it
    /// isn't running).
    public func run(_ command: ContainerCommand) async throws -> ContainerCommandOutput {
        let id = "command-" + UUID().uuidString.lowercased()
        let files = FileManager.default
        let folder = URL(fileURLWithPath: context.sessions, isDirectory: true).appendingPathComponent(".visor-commands", isDirectory: true)
        let input = folder.appendingPathComponent(id + ".in")
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard files.createFile(atPath: input.path, contents: command.input ?? Data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: input.path])
        }
        defer {
            try? files.removeItem(at: input)
            // The folder too, once no other command's input is in it.
            if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? files.removeItem(at: folder) }
        }
        var environment = command.environment
        environment["HOME"] = environment["HOME"] ?? "/root"
        environment["TMPDIR"] = "/tmp"
        environment["VISOR_COMMAND_INPUT"] = input.path
        let request = ContainerExec(id: id, arguments: ["/bin/sh", "-c", #"exec "$@" < "$VISOR_COMMAND_INPUT""#, "sh"] + command.arguments,
                                    environment: environment, workingDirectory: command.workingDirectory ?? context.sessions)
        let execution = try await exec(request)
        defer { try? files.removeItem(at: execution.log) }
        let ended = Mutex<Int32?>(nil)
        let waiting = Task {
            let status = await execution.wait()
            ended.withLock { $0 = status }
        }
        let deadline = ContinuousClock.now + command.limit
        var stopped = false
        while ended.withLock({ $0 }) == nil {
            let said = String(decoding: (try? Data(contentsOf: execution.log)) ?? Data(), as: UTF8.self)
            let late = command.stopping() || ContinuousClock.now >= deadline
            if late || command.answered(said) {
                stopped = late
                try? await execution.signal(9)
                break
            }
            try? await Task.sleep(for: Self.commandPoll)
        }
        await waiting.value
        let text = String(decoding: (try? Data(contentsOf: execution.log)) ?? Data(), as: UTF8.self)
        return ContainerCommandOutput(status: ended.withLock { $0 } ?? 137, text: text, stopped: stopped)
    }
}

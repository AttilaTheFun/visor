// What the Visor server runs in a session's container as it makes it and
// as it mirrors the agent's log: commands run to their end, each a process
// on oss whose output is read until it exits.

import Foundation
import OSSClient

extension OSSClient {
    /// The longest a read is held open for more to come.
    static let longestWait = 30

    /// A repository cloned into `folder` in the container, git's own end
    /// awaited (ten minutes at most); why not, when it was not.
    func clone(_ container: String, url: String, into folder: String) async throws {
        let ended = try await runToEnd(container, ["git", "clone", "-q", url, folder], limit: .seconds(600))
        guard let status = ended.status else { throw OSSError(status: 0, message: "Cloning \(url) took more than ten minutes.") }
        guard status != 0 else { return }
        throw OSSError(status: 0, message: "Cloning \(url) failed" + (ended.errors.isEmpty ? "." : ": \(ended.errors)"))
    }

    /// The container's own SSH key (`~/.ssh/id_ed25519`), made once: the
    /// key the agent's machine leases (oss's tools) are reached with.
    func makeSSHKey(_ container: String) async throws {
        let script = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && { [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C visor-agent -f ~/.ssh/id_ed25519; }"
        let ended = try await runToEnd(container, ["sh", "-c", script], limit: .seconds(60))
        guard ended.status == 0 else { throw OSSError(status: 0, message: "The container's SSH key was not made: \(ended.errors)") }
    }

    /// What a short command prints in the container, once it has run (a
    /// minute at most).
    func run(_ container: String, _ command: [String]) async throws -> String {
        try await runToEnd(container, command, limit: .seconds(60)).output
    }

    /// A command run in the container's home until it ends or `limit`
    /// passes (then killed): its output, its errors, and its exit status
    /// (nil when it ran past the limit or its container stopped under it).
    private func runToEnd(_ container: String, _ command: [String], limit: Duration) async throws -> (output: String, errors: String, status: Int32?) {
        let process = try await startProcess(container, ProcessRequest(command: command, directory: "/root")).id
        var output = Data(), errors = Data()
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let said = try await self.output(container, process, stream: .output, from: output.count, wait: Self.longestWait)
            output.append(said.data)
            guard said.state == .running || !said.data.isEmpty else {
                errors = try await self.output(container, process, stream: .errors, from: 0).data
                return (String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                        said.state == .exited ? said.status : nil)
            }
        }
        _ = try? await signal(container, process, "KILL")
        return (String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self), nil)
    }
}

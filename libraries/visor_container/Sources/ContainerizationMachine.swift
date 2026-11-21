// A booted Sessions container (ContainerMachine): a LinuxContainer, and its
// main process's settings, which each process exec'd starts from (the
// image's environment, working folder and user).

import Containerization
import Foundation
import VisorContainerCore

struct ContainerizationMachine: ContainerMachine {
    let container: LinuxContainer
    let base: LinuxProcessConfiguration

    func exec(_ process: ContainerProcessSpec) async throws -> any ContainerMachineProcess {
        var config = base
        config.arguments = process.arguments
        config.environmentVariables = Self.merged(base.environmentVariables, process.environment)
        if let directory = process.workingDirectory { config.workingDirectory = directory }
        config.terminal = false
        config.stdin = nil
        let log = try LogWriter(process.log)
        config.stdout = log
        config.stderr = log
        let started = try await container.exec(process.id, configuration: config)
        try await started.start()
        return ContainerizationProcess(process: started)
    }

    func waitMain() async -> Int32 {
        (try? await container.wait())?.exitCode ?? -1
    }

    func stop() async {
        try? await container.stop()
    }

    /// `NAME=VALUE`s with `extra` set over them.
    static func merged(_ list: [String], _ extra: [String: String]) -> [String] {
        guard !extra.isEmpty else { return list }
        let kept = list.filter { entry in !extra.keys.contains(String(entry.split(separator: "=", maxSplits: 1).first ?? "")) }
        return kept + extra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

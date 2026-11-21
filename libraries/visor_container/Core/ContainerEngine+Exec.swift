// A process run in the Sessions container (step 4 runs each session's
// agent-wrapper so): the container started first if it isn't running (its
// first use), refused while it has no egress, and counted while it runs, so
// the container isn't idle under it.

import Foundation
import VisorProtocol

extension ContainerEngine {
    /// `request` started in the container.
    public func exec(_ request: ContainerExec) async throws -> ContainerExecution {
        try await ensureStarted()
        guard state == .running, let machine, let layout else {
            if state == .noEgress { throw ContainerEngineError.noEgress(egress ?? "its egress check failed") }
            throw ContainerEngineError.notRunning
        }
        guard executions[request.id] == nil else { throw ContainerEngineError.duplicateProcess(request.id) }
        let log = request.log ?? layout.log(process: request.id)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let spec = ContainerProcessSpec(id: request.id, arguments: request.arguments, environment: request.environment,
                                        workingDirectory: request.workingDirectory, log: log)
        let process = try await machine.exec(spec)
        guard executions[request.id] == nil else {
            try? await process.signal(9)
            throw ContainerEngineError.duplicateProcess(request.id)
        }
        let started = generation
        let waiting = Task { [weak self] () -> Int32 in
            let status = (try? await process.wait()) ?? 137
            await self?.ended(request.id, generation: started)
            return status
        }
        let execution = ContainerExecution(id: request.id, log: log, process: process, waiting: waiting)
        executions[request.id] = execution
        idleSince = nil
        context.log("container: \(request.id) started (\(request.arguments.first ?? "?"))")
        return execution
    }

    /// The process `id` (of the boot `generation`) has ended.
    func ended(_ id: String, generation ended: Int) {
        guard ended == generation, executions.removeValue(forKey: id) != nil else { return }
        if executions.isEmpty { idleSince = context.now() }
    }

    /// The processes running in it now, by id.
    public var running: [String] { executions.keys.sorted() }
}

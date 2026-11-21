// A process running in the Sessions container, as ContainerEngine.exec gave
// it: signalled, and waited on (by as many as like).

import Foundation

public final class ContainerExecution: Sendable {
    public let id: String
    /// Its output's file.
    public let log: URL
    private let process: any ContainerMachineProcess
    private let waiting: Task<Int32, Never>

    init(id: String, log: URL, process: any ContainerMachineProcess, waiting: Task<Int32, Never>) {
        self.id = id
        self.log = log
        self.process = process
        self.waiting = waiting
    }

    /// Sent a signal (15 TERM, 9 KILL, …).
    public func signal(_ number: Int32) async throws {
        try await process.signal(number)
    }

    /// Its status once it has ended (137 when the container went under it).
    public func wait() async -> Int32 {
        await waiting.value
    }
}

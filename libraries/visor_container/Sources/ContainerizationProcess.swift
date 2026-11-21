// A process exec'd in the Sessions container (ContainerMachineProcess).

import Containerization
import Foundation
import VisorContainerCore

struct ContainerizationProcess: ContainerMachineProcess {
    let process: LinuxProcess

    func signal(_ number: Int32) async throws {
        try await process.kill(Signal(rawValue: number))
    }

    func wait() async throws -> Int32 {
        let status = try await process.wait()
        try? await process.delete()
        return status.exitCode
    }
}

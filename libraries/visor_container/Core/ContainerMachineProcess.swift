// A process exec'd in a container (ContainerMachine.exec).

public protocol ContainerMachineProcess: Sendable {
    /// Sent a signal (15 TERM, 9 KILL, …).
    func signal(_ number: Int32) async throws
    /// Its status once it has ended (128 + the signal for one killed).
    func wait() async throws -> Int32
}

// A ContainerBackend with no VM: a boot is recorded and answers at once;
// `relay-client check` ends with the status given (a line written to its
// log), and the authorities' trust at once; any other process runs until
// it's signalled or the machine stops;
// the main process ends when it's stopped, or when a test says it crashed.

import Foundation
import VisorContainerCore

actor FakeMachines: ContainerBackend {
    var checkStatus: Int32 = 0
    var failBoot = false
    private(set) var boots: [FakeMachine] = []

    func setCheckStatus(_ status: Int32) {
        checkStatus = status
        for machine in boots { Task { await machine.setCheckStatus(status) } }
    }

    func setFailBoot(_ fail: Bool) { failBoot = fail }

    func boot(_ spec: ContainerBootSpec) async throws -> any ContainerMachine {
        if failBoot { throw FakeBootError() }
        let machine = FakeMachine(spec: spec, checkStatus: checkStatus)
        boots.append(machine)
        return machine
    }

    var last: FakeMachine? { boots.last }
}

struct FakeBootError: Error, CustomStringConvertible {
    var description: String { "the fake VM wouldn't boot" }
}

actor FakeMachine: ContainerMachine {
    let spec: ContainerBootSpec
    var checkStatus: Int32
    private(set) var execs: [ContainerProcessSpec] = []
    private(set) var stopped = false
    private var processes: [FakeProcess] = []
    private var mainWaiters: [CheckedContinuation<Int32, Never>] = []
    private var mainStatus: Int32?

    init(spec: ContainerBootSpec, checkStatus: Int32) {
        self.spec = spec
        self.checkStatus = checkStatus
    }

    func setCheckStatus(_ status: Int32) { checkStatus = status }

    func exec(_ process: ContainerProcessSpec) async throws -> any ContainerMachineProcess {
        execs.append(process)
        if process.arguments == [ContainerEngine.relayClient, "check"] {
            let line = checkStatus == 0 ? "agent-proxy answers through the relay (/run/agent-proxy/relay.sock)\n"
                                        : "the relay (/run/agent-proxy/relay.sock) closed without an answer\n"
            try Self.append(line, to: process.log)
            return FakeProcess(ended: checkStatus)
        }
        // agent-proxy's authorities made the system's trust: done at once.
        if process.arguments.first == "/bin/sh", process.arguments.last?.contains("update-ca-certificates") == true {
            return FakeProcess(ended: 0)
        }
        let made = FakeProcess(ended: nil)
        processes.append(made)
        return made
    }

    func waitMain() async -> Int32 {
        if let mainStatus { return mainStatus }
        return await withCheckedContinuation { mainWaiters.append($0) }
    }

    func stop() async {
        stopped = true
        for process in processes { await process.end(137) }
        endMain(0)
    }

    /// Its main process dies under it.
    func crash(_ status: Int32) { endMain(status) }

    private func endMain(_ status: Int32) {
        guard mainStatus == nil else { return }
        mainStatus = status
        for waiter in mainWaiters { waiter.resume(returning: status) }
        mainWaiters = []
    }

    var checks: Int { execs.filter { $0.arguments.last == "check" }.count }

    static func append(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }
}

actor FakeProcess: ContainerMachineProcess {
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private(set) var signals: [Int32] = []

    init(ended: Int32?) { status = ended }

    func signal(_ number: Int32) async throws {
        signals.append(number)
        end(128 + number)
    }

    func wait() async throws -> Int32 {
        if let status { return status }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func end(_ code: Int32) {
        guard status == nil else { return }
        status = code
        for waiter in waiters { waiter.resume(returning: code) }
        waiters = []
    }
}

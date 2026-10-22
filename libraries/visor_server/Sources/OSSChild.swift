// An agent run in a container on an oss server (ContainerPlacement): oss
// keeps its standard input, output and errors, so it works on whatever
// becomes of the Visor server (a restart, an update, a crash), and a later
// server reads on from where the last one left off (StoredContainerProcess).
// Its adapter drives it as it would one on the server's own pipes.

import Foundation

@MainActor
final class OSSChild: AgentChild {
    let client: OSSClient
    /// oss's session: the container the agent runs in.
    let session: String
    /// The agent's process there, once started.
    private(set) var process: String?
    let output: AsyncStream<Data>
    private let said: AsyncStream<Data>.Continuation
    let errors: AsyncStream<Data>
    private let erred: AsyncStream<Data>.Continuation
    let notices: AsyncStream<String>
    private let noticed: AsyncStream<String>.Continuation
    let exit: Task<AgentExit, Never>
    private let exited: AsyncStream<AgentExit>.Continuation
    /// Its process id in the container.
    private(set) var pid: Int32 = 0
    private(set) var isRunning = true
    /// Where its output and its errors are read on from: where a later
    /// server picks up.
    private(set) var outOffset = 0
    private(set) var errOffset = 0
    /// The process started (or picked up): what is written waits for it.
    private var started: Task<String?, Never>?
    /// What is written, in order, one after the other.
    private var writing: Task<Void, Never>?
    private var readers: [Task<Void, Never>] = []

    private init(client: OSSClient, session: String) {
        self.client = client
        self.session = session
        (output, said) = AsyncStream.makeStream()
        (errors, erred) = AsyncStream.makeStream()
        (notices, noticed) = AsyncStream.makeStream()
        let (exits, exited) = AsyncStream.makeStream(of: AgentExit.self)
        self.exited = exited
        exit = Task {
            for await exit in exits { return exit }
            return AgentExit(status: -1, signaled: false)
        }
    }

    /// Starts `command` in the session's container, in `directory`, with
    /// `environment`; what is written before it has started waits for it,
    /// and a start that fails is said and ends it.
    static func start(client: OSSClient, session: String, command: [String], environment: [String: String], directory: String) -> OSSChild {
        let child = OSSChild(client: client, session: session)
        child.started = Task { [weak child] in
            do {
                let started = try await client.startProcess(session, command: command, environment: environment, directory: directory)
                child?.begin(process: started.id, pid: started.pid)
                return started.id
            } catch {
                child?.fail("Error: the agent could not be started in its container: \(error.localizedDescription)")
                return nil
            }
        }
        return child
    }

    /// The agent an earlier server left running in the container, read on
    /// from where that server left off.
    static func attach(client: OSSClient, session: String, process: String, out: Int, err: Int) -> OSSChild {
        let child = OSSChild(client: client, session: session)
        child.outOffset = out
        child.errOffset = err
        child.started = Task { process }
        child.begin(process: process, pid: 0)
        return child
    }

    private func begin(process: String, pid: Int32) {
        self.process = process
        self.pid = pid
        readers = [Task { [weak self] in await self?.follow("out", process: process) },
                   Task { [weak self] in await self?.follow("err", process: process) }]
    }

    /// One of its streams, as it comes; the output's end is the agent's.
    /// oss out of reach is asked again, less often the longer it is: the
    /// agent works on there meanwhile.
    private func follow(_ stream: String, process: String) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let from = stream == "out" ? outOffset : errOffset
                let got = try await client.output(session, process: process, stream: stream, from: from, wait: OSSClient.longestWait)
                failures = 0
                if !got.data.isEmpty {
                    if stream == "out" {
                        outOffset = got.next
                        said.yield(got.data)
                    } else {
                        errOffset = got.next
                        erred.yield(got.data)
                    }
                }
                guard got.state == "running" || !got.data.isEmpty else {
                    if stream == "out" { ended(AgentExit(status: Int32(got.status ?? -1), signaled: got.state == "lost")) } else { erred.finish() }
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                if failures == 3, stream == "out" { noticed.yield("oss can't be reached: the agent works on in its container, and is heard from again once oss answers.") }
                try? await Task.sleep(for: .seconds(min(30, 2 * failures)))
            }
        }
    }

    private func ended(_ exit: AgentExit) {
        guard isRunning else { return }
        isRunning = false
        said.finish()
        noticed.finish()
        exited.yield(exit)
        exited.finish()
    }

    private func fail(_ words: String) {
        erred.yield(Data((words + "\n").utf8))
        erred.finish()
        ended(AgentExit(status: -1, signaled: false))
    }

    // MARK: Writing

    func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        send(data, close: false)
    }

    func closeInput() { send(Data(), close: true) }

    private func send(_ data: Data, close: Bool) {
        let previous = writing, started = started, client = client, session = session
        writing = Task { [weak self] in
            await previous?.value
            guard let process = await started?.value else { return }
            do {
                try await client.input(session, process: process, data: data, close: close)
            } catch {
                self?.erred.yield(Data("Error: what was written to the agent did not reach it: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    // MARK: Ending

    /// End of input first, then, `grace` later, a request to terminate,
    /// and a second after that no choice.
    func end(grace: Duration) async {
        closeInput()
        if await gone(within: grace) { return }
        await signal("TERM")
        if await gone(within: .seconds(1)) { return }
        await signal("KILL")
        _ = await gone(within: .seconds(3))
    }

    /// Let go of without ending it: a server going for a restart, whose
    /// next launch picks it up where this one stopped reading.
    func detach() {
        for reader in readers { reader.cancel() }
        readers = []
    }

    private func gone(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return !isRunning
    }

    private func signal(_ name: String) async {
        guard let process = await started?.value else { return }
        try? await client.signal(session, process: process, name)
    }
}

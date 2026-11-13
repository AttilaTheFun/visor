// Visor's native runner (agent_protocol): on this computer, claims jobs
// from a dispatcher (Visor's server) and runs each agent under
// agent-wrapper, with the environment a runner gives it (AGENT_ID,
// AGENT_JOB, AGENT_DISPATCHER_URL, AGENT_DRIVER_URL, AGENT_RUNNER). While
// an agent runs its claim is renewed; the wrapper reports how the job
// went, and one that ends without reporting (not 0) has its job released.
// Native agents work as Visor's always have: in the user's own account,
// reading and writing where the user can (Logan, 12 Nov 2026).

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public actor NativeRunner {
    public let dispatcher: String
    let dispatcherHost: String
    let dispatcherPort: Int
    /// agent-wrapper's path.
    public let wrapper: String
    public let name: String
    public let capacity: Int
    /// The harnesses it runs.
    public let harnesses: [String]
    let log: @Sendable (String) -> Void

    private var running: [String: Process] = [:]

    /// Nil for a dispatcher address that isn't `http://host:port`.
    public init?(dispatcher: String, wrapper: String, name: String, capacity: Int = 4, harnesses: [String] = ["claude", "echo"],
                 log: @escaping @Sendable (String) -> Void) {
        guard let url = URLComponents(string: dispatcher), url.scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        self.dispatcher = dispatcher
        dispatcherHost = host
        dispatcherPort = url.port ?? 80
        self.wrapper = wrapper
        self.name = name
        self.capacity = capacity
        self.harnesses = harnesses
        self.log = log
    }

    /// Claims until cancelled: each job it is given started, its claim kept.
    public func run() async {
        var pause: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                let transport = try HTTP2ClientTransport.Posix(target: .dns(host: dispatcherHost, port: dispatcherPort), transportSecurity: .plaintext)
                try await withGRPCClient(transport: transport) { client in
                    try await self.claimLoop(AgentProtocol_V1_AgentDispatcher.Client(wrapping: client))
                }
                pause = .seconds(1)
            } catch {
                log("native runner: the dispatcher \(dispatcher): \(error)")
            }
            try? await Task.sleep(for: pause)
            pause = min(pause * 2, .seconds(30))
        }
    }

    private func claimLoop(_ dispatcher: AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>) async throws {
        while !Task.isCancelled {
            guard running.count < capacity else {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            var claim = AgentProtocol_V1_ClaimRequest()
            claim.runner = name
            claim.capabilities = ["native"] + harnesses.map { "harness:\($0)" }
            claim.waitSeconds = 25
            let answer = try await dispatcher.claim(claim)
            guard answer.hasJob else { continue }
            start(answer.job, dispatcher)
        }
    }

    /// A job's agent started under agent-wrapper, its claim kept until it ends.
    private func start(_ job: AgentProtocol_V1_Job, _ dispatcher: AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: wrapper)
        process.environment = environment(for: job)
        let folder = job.workingDirectory.isEmpty ? NSHomeDirectory() : (job.workingDirectory as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        // Its end, heard without blocking anyone.
        let (exits, exit) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { ended in
            exit.yield(ended.terminationStatus)
            exit.finish()
        }
        do {
            try process.run()
        } catch {
            Task { await release(job, "agent-wrapper didn't start: \(error)", dispatcher) }
            return
        }
        running[job.agent.uuid] = process
        log("native runner: started \(job.agent.uuid) (\(job.title)), pid \(process.processIdentifier)")
        Task {
            // The claim renewed while the agent runs.
            let renewing = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    if Task.isCancelled { return }
                    if let answer = try? await dispatcher.renew(.with { $0.agent = job.agent }), !answer.hasClaimExpires {
                        log("native runner: \(job.agent.uuid)'s claim isn't this runner's any more: stopping it")
                        process.terminate()
                        return
                    }
                }
            }
            var status: Int32 = -1
            for await ended in exits { status = ended }
            renewing.cancel()
            running[job.agent.uuid] = nil
            if status == 0 {
                log("native runner: \(job.agent.uuid) ended (its wrapper reported)")
            } else {
                await release(job, "agent-wrapper ended with status \(status)", dispatcher)
            }
        }
    }

    private func release(_ job: AgentProtocol_V1_Job, _ reason: String, _ dispatcher: AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>) async {
        log("native runner: \(job.agent.uuid) released: \(reason)")
        _ = try? await dispatcher.report(.with {
            $0.agent = job.agent
            $0.released = .with { $0.reason = reason }
        })
    }

    /// The wrapper's environment for a job: this process's, and the runner's contract.
    func environment(for job: AgentProtocol_V1_Job) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["AGENT_ID"] = "\(job.agent.uuid)@\(job.agent.dispatcherURL)"
        environment["AGENT_JOB"] = Self.json(job)
        environment["AGENT_DISPATCHER_URL"] = dispatcher
        environment["AGENT_RUNNER"] = name
        if job.driverURL.isEmpty { environment["AGENT_DRIVER_URL"] = nil } else { environment["AGENT_DRIVER_URL"] = job.driverURL }
        return environment
    }

    /// The job as AGENT_JOB's JSON.
    static func json(_ job: AgentProtocol_V1_Job) -> String {
        var object: [String: Any] = ["agent": job.agent.uuid, "dispatcherURL": job.agent.dispatcherURL, "title": job.title,
                                     "prompt": job.prompt, "sourceURL": job.sourceURL, "repository": job.repository, "ref": job.ref,
                                     "labels": job.labels]
        for (key, value) in [("harness", job.harness), ("model", job.model), ("effort", job.effort),
                             ("workingDirectory", job.workingDirectory), ("driverURL", job.driverURL),
                             ("resumeSessionID", job.resumeSessionID)] where !value.isEmpty {
            object[key] = value
        }
        if !job.sources.isEmpty {
            object["sources"] = job.sources.map { ["repository": $0.repository, "ref": $0.ref, "name": $0.name] }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

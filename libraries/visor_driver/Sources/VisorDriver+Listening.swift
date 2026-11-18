// The driver and dispatcher listening before the server they serve is
// there: a restarted server's port is open as soon as its system is set,
// before its sessions are read, so wrappers redialling and runners renewing
// find it at once rather than backing off. What they ask waits until the
// server is given (`serve`), and its driven sessions' moves are known to
// the queue (VisorServer.takeUpDrivenSessions): a renewal is never refused
// for want of them.

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import VisorServer
import VisorSystem

extension VisorDriver {
    @MainActor
    public final class Listening {
        let host: String
        let port: Int
        public let url: String
        let containerURL: String?
        let harness: String
        /// The queue, once listening (made then: jobs.json is found by the
        /// system's folders, set by then).
        private(set) var jobs: JobQueue?
        private var serving: Task<Void, Never>?
        private var lapsing: Task<Void, Never>?
        private(set) var server: VisorServer?
        private var waiters: [CheckedContinuation<VisorServer, Never>] = []

        /// `url` is this server's address as wrappers and runners reach it;
        /// `containerURL` as containers do (Shireworks' agent-proxy,
        /// `http://visor.agent.internal:<port>`), given to container runners
        /// in place of `url`; nil for the same. `harness` is what its jobs
        /// run ("echo" for a test without a model).
        public init(host: String, port: Int, url: String, containerURL: String? = nil, harness: String = "claude") {
            self.host = host
            self.port = port
            self.url = url
            self.containerURL = containerURL
            self.harness = harness
        }

        /// Listens now, if it isn't yet; what is asked waits for `serve`.
        public func listen() {
            guard jobs == nil else { return }
            // Kept beside the sessions, so a restart keeps runners' claims and
            // the moved sessions their agents carry on (JobQueue+Store).
            let file = HostFolders.dataFolder.appendingPathComponent("jobs.json", isDirectory: false)
            // Its agents' tokens are minted with the server's signing keys
            // once it is served (no call is answered before then).
            let jobs = JobQueue(dispatcherURL: url, driverURL: url, containerURL: containerURL, harness: harness, file: file)
            self.jobs = jobs
            let (host, port, url, containerURL) = (host, port, url, containerURL)
            serving = Task.detached { [self] in
                let services: [any RegistrableRPCService] = [DriverService(listening: self, jobs: jobs), DispatcherService(listening: self, jobs: jobs)]
                // A ping every two minutes on a quiet connection: the relays
                // between a container's wrapper and here (Shireworks'
                // agent-proxy) close one that is quiet for ten (13 Nov: a
                // moved session's wrapper redialled every ten minutes).
                let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: host, port: port), transportSecurity: .plaintext,
                                                           config: .defaults { $0.connection.keepalive.time = .seconds(120) })
                do {
                    try await withGRPCServer(transport: transport, services: services) { _ in
                        VisorServer.log("agent_protocol: driver and dispatcher on \(host):\(port), as \(url)"
                            + (containerURL.map { ", and to containers as \($0)" } ?? ""))
                        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                    }
                } catch {
                    VisorServer.log("agent_protocol: the driver and dispatcher couldn't serve on \(host):\(port): \(error)")
                }
            }
        }

        /// The server served from now on: its driven sessions' processes and
        /// its job queue given to it, their moves known to the queue, then
        /// what waited for it let through.
        public func serve(_ server: VisorServer) {
            listen()
            guard self.server == nil, let jobs else { return }
            server.jobs = jobs
            jobs.tokens = server.agentTokens
            jobs.liveSession = { [weak server] id in server?.session(id).map { !$0.info.archived } }
            jobs.moveFailed = { [weak server] session, resume, cwd, why in
                server?.moveBack(session, resume: resume, cwd: cwd, why: "the move to a runner failed: \(why)")
            }
            jobs.moveStarted = { [weak server] session, agent, conversation in
                server?.drivenAgentStarted(session, agent: agent, conversation: conversation)
            }
            jobs.moveRequeued = { [weak server] session, why in
                server?.drivenAgentRequeued(session, why: why)
            }
            server.drivenProcess = { _ in DrivenProcess() }
            server.takeUpDrivenSessions()
            self.server = server
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.resume(returning: server) }
            // Claims lapse even while no runner asks for work (a runner gone
            // with this server's restart): its sessions are told.
            lapsing = Task { [weak jobs] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    jobs?.releaseLapsed()
                }
            }
        }

        /// A runner token for this server's own runner, named `runner` (the
        /// native runner, in this process): held in memory, new each start,
        /// so it claims whether or not the server requires runner tokens.
        /// Nil before the server is served.
        public func runnerToken(for runner: String) -> String? {
            server?.runnerTokens.issueOwn(for: runner)
        }

        /// No longer listening, and its claims no longer lapsing: for a test
        /// that serves a server of its own.
        func stop() {
            serving?.cancel()
            serving = nil
            lapsing?.cancel()
            lapsing = nil
        }

        /// The server, once it is served.
        func ready() async -> VisorServer {
            if let server { return server }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }
}

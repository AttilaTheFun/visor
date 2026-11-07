import CVisorPOSIX
import Foundation
import Synchronization

/// A front's server, watched (docs/co-tenancy.md): every half minute the
/// Runner asks whether it answers at its address, and when it hasn't twice
/// running, starts it again with the front's command (`container exec -d
/// <container> visor-server start`), at most every two minutes. A server
/// that dies after the Runner started is up again within a minute, not
/// when someone notices.
public final class ServerWatch: Sendable {
    /// What has been heard of the server, and when it was last started.
    public struct State: Equatable, Sendable {
        /// Unanswered asks in a row.
        public var unanswered = 0
        public var started: ContinuousClock.Instant?

        /// Asks in a row unanswered before the server is started again:
        /// one is a moment (a restart of its own, a busy accept queue).
        public static let misses = 2
        /// The least time between two starts, while one comes up.
        public static let between: Duration = .seconds(120)

        public init() {}

        /// One ask's answer: whether to start the server now.
        public mutating func heard(answering: Bool, at now: ContinuousClock.Instant) -> Bool {
            guard !answering else {
                unanswered = 0
                return false
            }
            unanswered += 1
            guard unanswered >= Self.misses, started.map({ now - $0 >= Self.between }) ?? true else { return false }
            started = now
            return true
        }
    }

    public let front: ClientProxy.Front
    private let command: String
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())
    private let stopped = Mutex(false)

    /// Nil for a front with no command to start its server.
    public init?(front: ClientProxy.Front, log: @escaping @Sendable (String) -> Void) {
        guard let command = front.start, !command.isEmpty else { return nil }
        self.front = front
        self.command = command
        self.log = log
    }

    public func start(every interval: Duration = .seconds(30)) {
        Thread.detachNewThread { [self] in
            while !stopped.withLock({ $0 }) {
                check()
                Thread.sleep(forTimeInterval: Double(interval.components.seconds))
            }
        }
    }

    public func stop() { stopped.withLock { $0 = true } }

    /// One ask; the server started again if it is time.
    func check() {
        let connection = visor_connect_tcp(front.host, UInt16(clamping: front.hostPort))
        if connection >= 0 { close(connection) }
        guard state.withLock({ $0.heard(answering: connection >= 0, at: .now) }) else { return }
        log("\(front.name)'s server doesn't answer at \(front.host):\(front.hostPort): starting it again")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { log("\(front.name)'s start command exited with status \(process.terminationStatus)") }
        } catch {
            log("\(front.name)'s start command didn't run: \(error)")
        }
    }
}

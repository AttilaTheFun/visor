/// Work on the message cache, off the main actor and one job at a time in
/// the order it was asked for: a write never lands after a later one, and
/// a read sees every write asked for before it. A sync's rows, or a page
/// of earlier ones, are hundreds of rows to encode and write: done here,
/// the main actor only shows them.
public final class CacheQueue: Sendable {
    private let jobs: AsyncStream<@Sendable () -> Void>.Continuation

    public init() {
        let (stream, jobs) = AsyncStream<@Sendable () -> Void>.makeStream()
        self.jobs = jobs
        Task.detached(priority: .userInitiated) {
            for await job in stream { job() }
        }
    }

    /// Does `job` after everything asked for before it, without waiting.
    public func write(_ job: @escaping @Sendable () -> Void) {
        jobs.yield(job)
    }

    /// Does `job` after everything asked for before it, and answers with
    /// what it found.
    public func read<T: Sendable>(_ job: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { answer in
            jobs.yield { answer.resume(returning: job()) }
        }
    }

    /// Waits for everything asked for so far.
    public func drain() async {
        await read {}
    }
}

import Foundation

/// Looks at a file a few times a second: its size, when it changed, and
/// which file it is. What any system can do; one that announces writes
/// does better.
public struct PollingFileWatching: FileWatching {
    /// How often the file is looked at.
    let interval: Duration

    public init(interval: Duration = .milliseconds(250)) {
        self.interval = interval
    }

    /// What tells one look at the file from the next.
    private struct Look: Equatable {
        let identity: Int?
        let size: Int
        let modified: Date?

        init?(_ path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            identity = (attributes[.systemFileNumber] as? NSNumber)?.intValue
            size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            modified = attributes[.modificationDate] as? Date
        }
    }

    public func changes(to url: URL) -> AsyncStream<Bool>? {
        guard let first = Look(url.path) else { return nil }
        let interval = self.interval
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let looking = Task {
                var last = first
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let now = Look(url.path), now.identity == last.identity else {
                        // Gone, or another file in its place.
                        continuation.yield(false)
                        continuation.finish()
                        return
                    }
                    if now != last { continuation.yield(true) }
                    last = now
                }
            }
            continuation.onTermination = { _ in looking.cancel() }
        }
    }
}

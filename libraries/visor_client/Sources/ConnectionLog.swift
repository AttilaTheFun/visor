import Foundation
import VisorProtocol
import VisorServices

/// What the client did about its connections, a line per event with the
/// time: the app coming to the front and leaving it, each sign-in and how
/// long it took, each channel opened, answered and dropped, each retry and
/// how long it waits. Kept so that "this server took eight seconds to come
/// back" can be read off rather than guessed at: the server's settings
/// page exports it. The newest lines are kept, in memory and — when the
/// app leaves the front — in the host's settings, so the log of one run is
/// there in the next.
@MainActor
public final class ConnectionLog {
    public static let shared = ConnectionLog()

    /// How many lines are kept.
    static let limit = 1500
    private static let key = "connectionLog"

    public private(set) var lines: [String] = []
    /// The time, for the lines and for durations; a test sets its own.
    var now: () -> Double = { Date().timeIntervalSince1970 }
    private var loaded = false

    public init() {}

    /// One event: who it is about (a server's name, or "app") and what
    /// happened.
    public func note(_ subject: String, _ message: String) {
        load()
        lines.append(Self.stamp(now()) + "  " + subject + ": " + message)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }

    /// The whole log, oldest line first.
    public var text: String {
        load()
        return lines.joined(separator: "\n") + "\n"
    }

    public func clear() {
        lines = []
        loaded = true
        keep()
    }

    /// Saves the log where the next run finds it.
    public func keep() {
        guard !VisorFixture.active else { return }
        VisorHost.settings?.set(key: Self.key, value: lines.joined(separator: "\n"))
    }

    /// The lines of the run before, once, ahead of this run's.
    private func load() {
        guard !loaded else { return }
        loaded = true
        guard !VisorFixture.active, let saved = VisorHost.settings?.get(key: Self.key), !saved.isEmpty else { return }
        lines = saved.split(separator: "\n").map(String.init) + lines
    }

    /// Milliseconds from `start` (a `now()`) to now.
    func since(_ start: Double) -> Int { Int(((now() - start) * 1000).rounded()) }

    /// "10-03 15:06:41.250", in the device's own time.
    static func stamp(_ time: Double) -> String {
        let local = time + Double(TimeZone.current.secondsFromGMT())
        let days = Int((local / 86_400).rounded(.down))
        let inDay = local - Double(days) * 86_400
        let seconds = Int(inDay)
        let millis = Int(((inDay - Double(seconds)) * 1000).rounded(.down))
        // The civil date of a day count (Howard Hinnant's algorithm).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        func two(_ value: Int) -> String { String(value).leftPadded(2) }
        return two(month) + "-" + two(day) + " " + two(seconds / 3600) + ":" + two(seconds / 60 % 60) + ":" + two(seconds % 60)
            + "." + String(millis).leftPadded(3)
    }
}

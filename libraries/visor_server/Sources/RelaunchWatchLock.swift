// One update's watch at a time (NCH's check of #491: an update 43 seconds
// after another had the first one's watcher, still watching, take the new
// build's restart for a crash and undo it over the second's install,
// leaving no Visor.app at all). The watcher that relaunches the server
// (the server agent's ServerAgentWatch, the app's AppRelauncher) holds a
// lock file beside the rollback note while it watches: `<pid> <started>`.
//
// - A watcher takes it as it starts, stopping a previous one still
//   holding it first (TERM), and lets it go when it ends, if it's still
//   its own.
// - The server refuses a restart or an update (`/api/restart`: 409) while
//   a live watcher holds it, saying how long the watch has left.
// - Each watcher keeps the bundle it replaced in a folder of its own
//   (`Previous/<token>/`), and puts it back only if that copy is there and
//   the bundle in place is still the one it installed.

import Foundation

public enum RelaunchWatchLock {
    /// How long a watch lasts at most, for the 409's "try again in N s":
    /// the first answer's wait and the stay-up watch together.
    public static let longest = 600 + 120

    /// The lock file, beside the rollback note.
    @MainActor public static var url: URL {
        VisorServer.rollbackNoteURL.deletingLastPathComponent().appendingPathComponent("relaunch-watch.lock", isDirectory: false)
    }

    /// A folder of the watch's own for the bundle it replaces:
    /// `<beside the rollback note>/Previous/<token>/<bundle name>`.
    @MainActor public static func backup(for destination: String, token: String = UUID().uuidString.prefix(8).lowercased()) -> String {
        VisorServer.rollbackNoteURL.deletingLastPathComponent()
            .appendingPathComponent("Previous", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
            .appendingPathComponent((destination as NSString).lastPathComponent, isDirectory: true).path
    }

    /// What the lock file says: the watcher's pid and when it started
    /// (seconds since 1970); nil when it says nothing readable.
    public static func read(_ text: String) -> (pid: Int32, started: Int)? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let pid = Int32(words[0]), pid > 1, let started = Int(words[1]) else { return nil }
        return (pid, started)
    }

    /// Seconds the watch holding the lock has left, at most, while a live
    /// watcher holds it; nil when none does.
    public static func remaining(_ text: String?, now: Int, isRunning: (Int32) -> Bool) -> Int? {
        guard let text, let (pid, started) = read(text), isRunning(pid) else { return nil }
        return max(5, started + longest - now)
    }

    /// Shell, at a watcher's start: a previous watcher still holding the
    /// lock is stopped, the lock taken (this shell's pid, the time), and let
    /// go at the end if it's still this one's.
    public static func take(_ lock: String) -> String {
        """
        lockfile=\(quoted(lock))
        old=$(sed -n '1s/ .*//p' "$lockfile" 2>/dev/null)
        if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
          echo "$(date): stopping the watch of an earlier update (process $old)"; kill "$old" 2>/dev/null; sleep 1
        fi
        mkdir -p "$(dirname "$lockfile")" && printf '%s %s\\n' "$$" "$(date +%s)" > "$lockfile"
        trap '[ "$(sed -n "1s/ .*//p" "$lockfile" 2>/dev/null)" = "$$" ] && rm -f "$lockfile"' EXIT
        """
    }

    /// A path as one shell word.
    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

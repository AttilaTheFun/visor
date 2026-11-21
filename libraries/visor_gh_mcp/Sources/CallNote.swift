import Foundation
import Synchronization

/// What a call keeps for its log line (the repository it touched, once
/// known). In Visor, behind a Mutex (gh_mcp's was a lock of Foundation's).
final class CallNote: Sendable {
    private let kept = Mutex<String?>(nil)

    var repo: String? {
        get { kept.withLock { $0 } }
        set { kept.withLock { $0 = newValue } }
    }
}

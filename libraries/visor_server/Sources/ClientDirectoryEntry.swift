import Foundation
import VisorProtocol

/// A client's last report to this server (`POST /api/relay`): the servers
/// it is connected to and their sessions, and when it said so.
struct ClientDirectoryEntry {
    var report: DirectoryReport
    var at: Date
}

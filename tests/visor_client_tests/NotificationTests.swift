// What a session's changes tell the user: a turn finished, an agent
// waiting for approval, a goal done. A notification's id names its
// computer and session whatever the computer's address holds (a URL's
// slashes), and one made the old way still reads; a turn that finished
// says the agent's words, or that it is ready, never the user's own
// message back.

@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class NotificationTests: XCTestCase {
    final class Told: VisorNotificationService {
        var said: [(id: String, title: String, body: String)] = []
        func requestPermission() {}
        func notify(id: String, title: String, body: String) { said.append((id, title, body)) }
    }

    func testChangesThatAreTold() {
        let told = Told()
        VisorHost.notifications = told
        defer { VisorHost.notifications = nil }
        let host = AgentServerConnection(record: AgentServerRecord(id: "h", name: "Mac", address: "mac.local", secret: ""))
        var working = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "Sync", busy: true, created: 0)
        working.goal = "Ship it"
        var done = working
        done.busy = false
        done.goal = nil
        done.preview = "Shipped."
        host.notifyChanges(from: [working], to: [done])
        XCTAssertEqual(told.said.map(\.title), ["Sync: goal done"], "a goal done says so, not also the turn")
        var waiting = done
        waiting.goal = nil
        waiting.pendingApproval = ApprovalRequest(id: "a", tool: "Bash", summary: "rm -rf build")
        var idle = done
        idle.goal = nil
        host.notifyChanges(from: [idle], to: [waiting])
        XCTAssertEqual(told.said.last?.title, "Sync is waiting")
        XCTAssertEqual(told.said.last?.body, "Allow Bash? rm -rf build")
        var busy = idle
        busy.busy = true
        host.notifyChanges(from: [busy], to: [idle])
        XCTAssertEqual(told.said.last?.title, "Sync finished")
        XCTAssertEqual(told.said.last?.id, VisorNotificationID(computer: "mac.local", session: "s", kind: "turn").rawValue)
        // A session seen for the first time is not news.
        let count = told.said.count
        host.notifyChanges(from: [], to: [idle])
        XCTAssertEqual(told.said.count, count)
    }

    /// A turn that ends on what it began with — the user's message, the
    /// reply not read yet — says it is ready; one that ends on the
    /// agent's words says them, however soon they were listed.
    func testAFinishedTurnNeverSaysTheUsersOwnMessage() {
        let told = Told()
        VisorHost.notifications = told
        defer { VisorHost.notifications = nil }
        let host = AgentServerConnection(record: AgentServerRecord(id: "h", name: "Mac", address: "mac.local", secret: ""))
        var idle = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "Fix", created: 0)
        idle.preview = "Earlier reply."
        var asked = idle
        asked.busy = true
        asked.preview = "Please fix the build"
        var ended = asked
        ended.busy = false
        host.notifyChanges(from: [idle], to: [asked])
        host.notifyChanges(from: [asked], to: [ended])
        XCTAssertEqual(told.said.last?.body, "Ready for your reply")
        // The reply listed while the turn still ran, then the turn ending.
        var replied = asked
        replied.preview = "Fixed: the import was missing."
        var finished = replied
        finished.busy = false
        host.notifyChanges(from: [ended], to: [asked])
        host.notifyChanges(from: [asked], to: [replied])
        host.notifyChanges(from: [replied], to: [finished])
        XCTAssertEqual(told.said.last?.body, "Fixed: the import was missing.")
    }

    func testAnIDNamesItsComputerAndSessionWhateverTheAddressHolds() throws {
        let id = VisorNotificationID(computer: "https://host/path", session: "abc", kind: "turn")
        let target = try XCTUnwrap(VisorNotificationID.target(of: id.rawValue))
        XCTAssertEqual(target.computer, "https://host/path")
        XCTAssertEqual(target.session, "abc")
        XCTAssertEqual(id.thread, "https://host/path\u{1E}abc")
    }

    func testAnOldIDStillReads() throws {
        let target = try XCTUnwrap(VisorNotificationID.target(of: "studio.local:7878/abc/approval"))
        XCTAssertEqual(target.computer, "studio.local:7878")
        XCTAssertEqual(target.session, "abc")
        XCTAssertNil(VisorNotificationID.target(of: "abc"))
    }
}

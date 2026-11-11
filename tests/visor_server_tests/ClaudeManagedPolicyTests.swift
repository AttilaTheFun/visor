// Claude under an administrator's managed settings: where they disable
// bypassing permissions and not auto mode, an auto-approving session
// starts Claude in auto mode; where they disable both, Claude starts in
// another mode than asked and says so, and the session becomes Manual.
// An unmanaged computer is as before.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class ClaudeManagedPolicyTests: ServerTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-managed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func settings(_ permissions: [String: String], plist: Bool = false) throws -> String {
        let file = folder.appendingPathComponent(UUID().uuidString + (plist ? ".plist" : ".json"))
        let object: [String: Any] = ["permissions": permissions]
        let data = plist ? try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            : try JSONSerialization.data(withJSONObject: object)
        try data.write(to: file)
        return file.path
    }

    func testAPolicyDisablingBypassStartsClaudeInAutoMode() throws {
        let policy = ClaudeManagedPolicy.read([try settings(["disableBypassPermissionsMode": "disable"])])
        XCTAssertEqual(policy, ClaudeManagedPolicy(bypassDisabled: true, autoDisabled: false))
        XCTAssertEqual(ClaudeProcess.permissionMode(skip: true, tool: "claude", policy: policy, contained: true), "auto")
        // Manual is as it was, and another CLI is not Claude's to manage.
        XCTAssertEqual(ClaudeProcess.permissionMode(skip: false, tool: "claude", policy: policy, contained: true), "acceptEdits")
        XCTAssertEqual(ClaudeProcess.permissionMode(skip: true, tool: "openrouter", policy: policy, contained: true), "bypassPermissions")
        // Managed preferences say it the same way.
        let preferences = ClaudeManagedPolicy.read([try settings(["disableBypassPermissionsMode": "disable"], plist: true)])
        XCTAssertEqual(preferences.autoApproveMode(contained: true), "auto")
    }

    func testAPolicyDisablingBothLeavesTheSessionManual() throws {
        let policy = ClaudeManagedPolicy.read([try settings(["disableBypassPermissionsMode": "disable"]),
                                               try settings(["disableAutoMode": "disable"])])
        XCTAssertEqual(ClaudeProcess.permissionMode(skip: true, tool: "claude", policy: policy, contained: true), "bypassPermissions")
        // Claude says it started in its default mode: not the one asked.
        let began = ClaudeOutput.parse(#"{"type":"system","subtype":"init","session_id":"s","permissionMode":"default"}"#)
        XCTAssertEqual(began, [.began(session: "s", model: nil, keySource: nil, mode: "default")])
        XCTAssertTrue(ClaudeProcess.startedOtherwise(asked: "bypassPermissions", reported: "default"))
        XCTAssertFalse(ClaudeProcess.startedOtherwise(asked: "auto", reported: "auto"))
        // The session becomes Manual, and says why.
        let record = SessionRecord(info: SessionInfo(id: "M", agent: .claude, cwd: "/tmp", title: "Claude", created: 0),
                                   process: ClaudeProcess(cwd: "/tmp", skipPermissions: true), entries: [])
        _ = record.apply(.manual("Claude started in its default mode."))
        XCTAssertFalse(record.info.skipPermissions)
        XCTAssertFalse(record.process.skipPermissions)
        XCTAssertEqual(record.notice, "Claude started in its default mode.")
    }

    func testAnUnmanagedComputerIsAsBefore() throws {
        let policy = ClaudeManagedPolicy.read([folder.appendingPathComponent("missing.json").path,
                                               try settings(["disableBypassPermissionsMode": "allow"])])
        XCTAssertEqual(policy, ClaudeManagedPolicy())
        XCTAssertEqual(ClaudeProcess.permissionMode(skip: true, tool: "claude", policy: policy, contained: true), "bypassPermissions")
    }

    /// On the computer itself an auto-approving session is Claude's own auto
    /// mode, never a bypass, whatever the policy; the OpenRouter CLI, with
    /// no auto mode, asks (Logan, 11 Nov).
    func testOnTheComputerItselfAutoApprovingIsClaudesAutoModeNeverABypass() {
        for policy in [ClaudeManagedPolicy(), ClaudeManagedPolicy(bypassDisabled: true, autoDisabled: false)] {
            XCTAssertEqual(ClaudeProcess.permissionMode(skip: true, tool: "claude", policy: policy, contained: false), "auto")
        }
        XCTAssertEqual(ClaudeProcess.permissionMode(skip: false, tool: "claude", policy: ClaudeManagedPolicy(), contained: false), "acceptEdits")
        XCTAssertEqual(ClaudeProcess.permissionMode(skip: true, tool: "openrouter", policy: ClaudeManagedPolicy(), contained: false), "acceptEdits")
    }
}

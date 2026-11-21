// Uninstall…'s plan: every item it would stop, remove, list, delete or
// print, from a fake Mac's home folder and keychain.

import DiskVolumes
import Foundation
import Testing
import VisorUninstall

@Suite struct PlanTests {
    static let home = "/Users/someone"
    static let group = "team.com.LoganShire.Visor"

    /// A Mac Visor was used on: the app, its plists, logs and leftovers.
    static func usedMac(zshrc: String? = nil) -> FakeFiles {
        var paths: [String: String?] = [
            "/Applications/Visor.app/Contents/MacOS/Visor": "",
            "/Applications/Visor Disk Utility.app/Contents/MacOS/Visor Disk Utility": "",
            "\(home)/Library/LaunchAgents/com.LoganShire.Visor.agent-proxy.plist": "",
            "\(home)/Library/LaunchAgents/com.LoganShire.Visor.server.plist": "",
            "\(home)/Library/LaunchAgents/com.example.other.plist": "",
            "\(home)/Library/Preferences/com.LoganShire.Visor.plist": "",
            "\(home)/Library/Preferences/com.LoganShire.Visor.DiskUtility.plist": "",
            "\(home)/Library/Saved Application State/com.LoganShire.Visor.savedState/windows.plist": "",
            "\(home)/.visor/server.sock": "",
            "\(home)/Library/Application Support/Visor/Sessions/Claude/abc/notes.md": "",
            "\(home)/Library/Application Support/com.LoganShire.Visor/Client/messages.sqlite": "",
            "\(home)/Library/Logs/Visor-server.log": "",
            "\(home)/Library/Logs/Visor-egress.log": "",
            "\(home)/Library/Logs/Other.log": "",
            "\(home)/Library/HTTPStorages/com.LoganShire.Visor/httpstorages.sqlite": "",
            "\(home)/.ssh/authorized_keys": """
                ssh-ed25519 AAAAphone visor:Logans-iPhone
                ssh-ed25519 AAAAbyhand me@laptop
                ssh-ed25519 AAAAolder visor
                ssh-ed25519 AAAAmac visor:Mini
                """,
            "\(home)/.claude/projects/-Volumes-Sessions-Claude-1234/a.jsonl": "",
            "\(home)/.claude/projects/-Users-someone-Developer-visor/b.jsonl": "",
        ]
        if let zshrc { paths["\(home)/.zshrc"] = zshrc }
        return FakeFiles(paths)
    }

    static let keychain = FakeKeychain(items: [
        "com.LoganShire.Visor.server": ["": ["password", "adminTokenHash"], group: ["appKey"]],
        "com.LoganShire.Visor": ["": ["host.key"]],
    ])

    func planner(group: String? = PlanTests.group, volumes: [VolumeState] = [], deleting: Bool = false) -> UninstallPlanner {
        UninstallPlanner(home: Self.home, accessGroup: group, volumes: volumes, deleteVolumes: deleting)
    }

    @Test func everythingVisorLeftIsPlannedInOrder() {
        let plan = planner().plan(files: Self.usedMac(), keychain: Self.keychain)
        let removes = plan.steps(.remove).map(\.action)
        let library = "\(Self.home)/Library"
        #expect(removes == [
            .quit(bundleID: "com.LoganShire.Visor"),
            .unregisterServerAgent(executable: "/Applications/Visor.app/Contents/MacOS/Visor"),
            .removeLaunchAgent(label: "com.LoganShire.Visor.server", plist: "\(library)/LaunchAgents/com.LoganShire.Visor.server.plist"),
            .removeLaunchAgent(label: "com.LoganShire.Visor.agent-proxy",
                               plist: "\(library)/LaunchAgents/com.LoganShire.Visor.agent-proxy.plist"),
            .endAgentHosts(program: "/Applications/Visor.app/Contents/Helpers/visor-agent-host"),
            .deleteKeychainItems(service: "com.LoganShire.Visor.server", accessGroup: nil, accounts: ["password", "adminTokenHash"]),
            .deleteKeychainItems(service: "com.LoganShire.Visor.server", accessGroup: Self.group, accounts: ["appKey"]),
            .deleteKeychainItems(service: "com.LoganShire.Visor", accessGroup: nil, accounts: ["host.key"]),
            .deleteDefaults(domain: "com.LoganShire.Visor"),
            .remove(path: "\(library)/Saved Application State/com.LoganShire.Visor.savedState"),
            .deleteDefaults(domain: "com.LoganShire.Visor.DiskUtility"),
            .resetPrivacy(bundleID: "com.LoganShire.Visor"),
            .removeKeyLines(file: "\(Self.home)/.ssh/authorized_keys",
                            lines: ["ssh-ed25519 AAAAphone visor:Logans-iPhone", "ssh-ed25519 AAAAolder visor", "ssh-ed25519 AAAAmac visor:Mini"]),
            .remove(path: "\(Self.home)/.visor"),
            .remove(path: "\(library)/Application Support/Visor"),
            .remove(path: "\(library)/Application Support/com.LoganShire.Visor"),
            .remove(path: "\(library)/HTTPStorages/com.LoganShire.Visor"),
            .remove(path: "\(library)/Logs/Visor-egress.log"),
            .remove(path: "\(library)/Logs/Visor-server.log"),
        ])
        // Claude Code's own folders are listed, never removed; only those of
        // sessions on Sessions.
        #expect(plan.steps(.list).map(\.action) == [.list(path: "\(Self.home)/.claude/projects/-Volumes-Sessions-Claude-1234")])
        #expect(plan.steps(.list).allSatisfy { !$0.changes })
        // No volumes unless asked; the apps last.
        #expect(plan.volumes.isEmpty)
        #expect(plan.steps(.trash).map(\.action) == [.trash(path: "/Applications/Visor.app"), .trash(path: "/Applications/Visor Disk Utility.app")])
        #expect(plan.steps.last?.stage == .note)
        // Nothing of anyone else's.
        let said = plan.dryRun
        #expect(!said.contains("com.example.other"))
        #expect(!said.contains("Other.log"))
        #expect(!said.contains("AAAAbyhand"))
        #expect(!said.contains("Developer-visor"))
    }

    @Test func theDryRunSaysEachStageInTurn() {
        let said = planner().plan(files: Self.usedMac(), keychain: Self.keychain).dryRun
        let stages = ["Stopped and removed:", "Listed, not removed", "Moved to the Trash, last:", "Not done by Uninstall…"]
        let at = stages.compactMap { said.range(of: $0)?.lowerBound }
        #expect(at.count == stages.count)
        #expect(at == at.sorted())
        #expect(said.contains("tailscale serve status"))
        #expect(!said.contains("Deleted, as you asked"))
    }

    @Test func aCleanMacHasNothingButTheAlwaysSteps() {
        let plan = planner().plan(files: FakeFiles([:]), keychain: FakeKeychain(items: [:]))
        #expect(plan.steps(.remove).map(\.action) == [.quit(bundleID: "com.LoganShire.Visor"),
                                                      .endAgentHosts(program: "/Applications/Visor.app/Contents/Helpers/visor-agent-host"),
                                                      .resetPrivacy(bundleID: "com.LoganShire.Visor")])
        #expect(plan.steps(.trash).isEmpty)
        #expect(plan.steps(.list).isEmpty)
    }

    @Test func withoutTheAccessGroupTheProtectedItemsAreSaidNotDone() {
        let plan = planner(group: nil).plan(files: Self.usedMac(), keychain: Self.keychain)
        #expect(!plan.steps.contains { $0.action == .deleteKeychainItems(service: "com.LoganShire.Visor.server", accessGroup: Self.group,
                                                                             accounts: ["appKey"]) })
        #expect(plan.steps(.note).contains { $0.what.contains("isn't signed with Visor's keychain access group") })
    }

    @Test func theAdminTokensExportIsNamedByItsLineAlone() {
        let zshrc = "export PATH=/x:$PATH\n  export VISOR_ADMIN_TOKEN=0123456789abcdef\nalias v=visor\n"
        let plan = planner().plan(files: Self.usedMac(zshrc: zshrc), keychain: Self.keychain)
        let note = plan.steps(.note).map(\.what).first { $0.contains("VISOR_ADMIN_TOKEN") }
        #expect(note?.contains("line 2") == true)
        #expect(!plan.dryRun.contains("0123456789abcdef"), "the token itself is never said")
        #expect(UninstallPlanner.adminTokenExport(in: "VISOR_ADMIN_TOKEN=x") == 1)
        #expect(UninstallPlanner.adminTokenExport(in: "echo $VISOR_ADMIN_TOKEN") == nil)
        #expect(UninstallPlanner.adminTokenExport(in: nil) == nil)
    }

    @Test func theVolumesAreDeletedOnlyWhenAskedAndOnlyVisorsOwn() throws {
        let sessions = VolumeState(role: .sessions, plan: .adopt,
                                   volume: APFSVolume(device: "disk3s7", name: "Sessions", uuid: "86410F75-D43C-49E6-95C6-B20A5CBB16F2"),
                                   info: VolumeInfo(device: "disk3s7", volumeName: "Sessions", mountPoint: "/Volumes/Sessions",
                                                    filesystemName: "Case-sensitive APFS", containerReference: "disk3"))
        let visor = VolumeState(role: .visor, plan: .adopt,
                                volume: APFSVolume(device: "disk3s8", name: "Visor", uuid: "4EF85269-E4B1-4058-A1FA-E9240A971CC9"))
        // Someone else's at Sources' mount point, by another name: never.
        let other = VolumeState(role: .sources, plan: .adopt, volume: APFSVolume(device: "disk3s9", name: "Work", uuid: "0A0B0C0D-1111-2222-3333-444455556666"))
        let volumes = [sessions, other, visor]
        #expect(planner(volumes: volumes).plan(files: Self.usedMac(), keychain: Self.keychain).volumes.isEmpty)
        let plan = planner(volumes: volumes, deleting: true).plan(files: Self.usedMac(), keychain: Self.keychain)
        #expect(plan.volumes == [.sessions, .visor])
        #expect(plan.steps(.volumes).map(\.action) == [.deleteVolume(role: .sessions, uuid: "86410F75-D43C-49E6-95C6-B20A5CBB16F2"),
                                                       .deleteVolume(role: .visor, uuid: "4EF85269-E4B1-4058-A1FA-E9240A971CC9")])
        // Before the apps go to the Trash.
        let volumesAt = try #require(plan.steps.firstIndex { $0.stage == .volumes })
        let trashAt = try #require(plan.steps.firstIndex { $0.stage == .trash })
        #expect(volumesAt < trashAt)
        #expect(plan.dryRun.contains("Deleted, as you asked"))
    }

    @Test func theVolumesTakeTheirNamesTyped() {
        #expect(UninstallConfirmation.phrase(for: [.sessions, .sources, .visor]) == "delete Sessions, Sources and Visor")
        #expect(UninstallConfirmation.phrase(for: [.visor]) == "delete Visor")
        #expect(UninstallConfirmation.matches(" delete Sessions, Sources and Visor\n", roles: [.sessions, .sources, .visor]))
        #expect(!UninstallConfirmation.matches("delete sessions, sources and visor", roles: [.sessions, .sources, .visor]))
        #expect(!UninstallConfirmation.matches("yes", roles: [.visor]))
        #expect(!UninstallConfirmation.matches("delete ", roles: []))
    }

    @Test func visorsKeyLinesAndProjectKeys() {
        #expect(UninstallPlanner.isVisorsKeyLine("ssh-ed25519 AAAA visor:Mini"))
        #expect(UninstallPlanner.isVisorsKeyLine("ssh-ed25519 AAAA visor"))
        #expect(!UninstallPlanner.isVisorsKeyLine("ssh-ed25519 AAAA visor@box"))
        #expect(!UninstallPlanner.isVisorsKeyLine("ssh-ed25519 AAAA my visor"))
        #expect(UninstallPlanner.projectKey(of: "/Volumes/Sessions") == "-Volumes-Sessions")
        #expect(UninstallPlanner.projectKey(of: "/Users/a.b/x") == "-Users-a-b-x")
    }
}

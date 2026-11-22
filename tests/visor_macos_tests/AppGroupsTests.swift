// The app groups CI's builds of Visor.app and Visor Disk Utility ask for
// (tools/app_groups): the Visor family's, `group.com.LoganShire.Visor`,
// first, then Applications' where the builder has it (UPDATE_APP_GROUP,
// which CI's distribution builds set; none here), in one
// `com.apple.security.application-groups`, beside each app's identifier
// and Visor's keychain access group, the team the builder's.

import Foundation
import Testing

@Suite struct AppGroupsTests {
    /// CI's entitlements of the app in `folder`, from the test's runfiles.
    static func entitlements(of folder: String) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/applications/\(folder)/app_ci_entitlements.entitlements"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test(arguments: [("visor_mac", "com.LoganShire.Visor"), ("visor_disk_utility", "com.LoganShire.Visor.DiskUtility")])
    func theVisorFamilysGroupComesFirst(folder: String, bundleID: String) throws {
        let entitlements = try Self.entitlements(of: folder)
        let groups = try #require(entitlements["com.apple.security.application-groups"] as? [String])
        #expect(groups.first == "group.com.LoganShire.Visor")
        #expect(Set(groups).count == groups.count)
        #expect(groups.dropFirst().allSatisfy { $0.hasPrefix("group.") && $0 != "group.com.LoganShire.Visor" },
                "Applications' group alone after it, where the builder has one")
        // The team the builder's, never the variable rules_apple refuses.
        let identifier = try #require(entitlements["com.apple.application-identifier"] as? String)
        #expect(identifier.hasSuffix("." + bundleID) && !identifier.hasPrefix("$("))
        let keychain = try #require(entitlements["keychain-access-groups"] as? [String])
        #expect(keychain.count == 1 && keychain[0].hasSuffix(".com.LoganShire.Visor") && !keychain[0].hasPrefix("$("))
    }
}

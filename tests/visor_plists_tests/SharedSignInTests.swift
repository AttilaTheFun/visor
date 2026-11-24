// The sign-in Logan's apps share (Shireworks Kit's GitHubShared… keys,
// with ShireworksRepository), stamped into CI's builds to publish alone
// (tools/shared_sign_in): with all of it, or none. A builder without it
// (this test's, anyone's but CI's) gets an empty fragment and no shared
// keychain group: Shireworks Kit, whose only sign-in that is, then files
// nothing. Visor, on the Mac and on iOS, and Visor Disk Utility.

import Foundation
import Testing

@Suite struct SharedSignInTests {
    static let keys: Set = ["GitHubSharedClientID", "GitHubSharedKeychainGroup", "GitHubSharedLockGroup", "GitHubSharedKeychainService",
                            "ShireworksRepository"]

    /// Shireworks Kit's keys CI stamps in (tools/signing, tools/variant,
    /// tools/shared_sign_in): never in an app's own Info.plist.
    static let stamped: Set = keys.union(["UpdateKitAppGroup", "UpdateKitApplicationsBundleIDs", "BuildVariant", "ShakeKitScope"])

    /// A file of the build's, from the test's runfiles.
    static func plist(_ path: String) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/\(path)"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test(arguments: ["visor_mac", "visor_ios", "visor_disk_utility"])
    func allOfItOrNone(folder: String) throws {
        let fragment = try Self.plist("applications/\(folder)/shared_sign_in_plist.plist")
        if fragment.isEmpty { return }
        #expect(Set(fragment.keys) == Self.keys)
        #expect(fragment["GitHubSharedKeychainService"] as? String == "com.LoganShire.github")
        let group = try #require(fragment["GitHubSharedKeychainGroup"] as? String)
        #expect(group.hasSuffix(".com.LoganShire.github") && !group.contains("$("))
        #expect((fragment["GitHubSharedLockGroup"] as? String)?.hasPrefix("group.") == true)
        #expect((fragment["GitHubSharedClientID"] as? String)?.isEmpty == false)
        #expect(fragment["ShireworksRepository"] as? String == "AttilaTheFun/visor")
    }

    /// An app's own Info.plist carries none of Shireworks Kit's keys: CI's
    /// builds to publish have them stamped in. (ShakeKitScope isn't one at
    /// all: this public repository takes the kit's default, public_repo.)
    @Test(arguments: ["visor_mac", "visor_ios", "visor_disk_utility"])
    func noneIsCommitted(folder: String) throws {
        let info = try Self.plist("applications/\(folder)/Info.plist")
        #expect(Set(info.keys).isDisjoint(with: Self.stamped))
        #expect(info["ShakeKitClientID"] == nil)
    }
}

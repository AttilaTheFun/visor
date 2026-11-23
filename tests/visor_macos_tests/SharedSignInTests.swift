// The sign-in Logan's apps share (ShakeKit's GitHubShared… keys), stamped
// into CI's builds to publish alone (tools/shared_sign_in): with all of
// it, or none. A builder without it (this test's, anyone's but CI's) gets
// an empty fragment and no shared keychain group, so the apps sign in with
// ShakeKit's own OAuth App.

import Foundation
import Testing

@Suite struct SharedSignInTests {
    static let keys: Set = ["GitHubSharedClientID", "GitHubSharedKeychainGroup", "GitHubSharedLockGroup", "GitHubSharedKeychainService"]

    /// A file of the build's, from the test's runfiles.
    static func plist(_ path: String) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/\(path)"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test(arguments: ["visor_mac", "visor_ios", "visor_macos"])
    func allOfItOrNone(folder: String) throws {
        let fragment = try Self.plist("applications/\(folder)/shared_sign_in_plist.plist")
        if fragment.isEmpty { return }
        #expect(Set(fragment.keys) == Self.keys)
        #expect(fragment["GitHubSharedKeychainService"] as? String == "com.LoganShire.github")
        let group = try #require(fragment["GitHubSharedKeychainGroup"] as? String)
        #expect(group.hasSuffix(".com.LoganShire.github") && !group.contains("$("))
        #expect((fragment["GitHubSharedLockGroup"] as? String)?.hasPrefix("group.") == true)
        #expect((fragment["GitHubSharedClientID"] as? String)?.isEmpty == false)
    }

    /// A build's own Info.plist turns ShakeKit on in every build.
    @Test(arguments: ["visor_mac", "visor_ios", "visor_macos"])
    func everyBuildOptsIn(folder: String) throws {
        let info = try Self.plist("applications/\(folder)/Info.plist")
        #expect(info["ShakeKitScope"] as? String == "public_repo")
        #expect(info["ShakeKitClientID"] == nil)
        #expect(Set(info.keys).isDisjoint(with: Self.keys))
    }
}

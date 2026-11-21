// Visor Client is sandboxed, and asks for nothing beyond its list (Logan,
// 21 Nov 2026: a client on a Mac kept pristine): the App Sandbox, the
// network as a client, the microphone and the files the person picks, read
// only; and in CI's build, which Shireworks' signing signs with the
// Developer ID profile, push and its own keychain access group, with the
// application identifier the signer makes the profile's. Never the network
// as a server, files it may write, another app's group, or a server's.

import Foundation
import Testing

@Suite struct EntitlementsTests {
    static let bundleID = "com.LoganShire.VisorClient.macOS"

    /// What every build has, and its value.
    static let everywhere: [String: Bool] = [
        "com.apple.security.app-sandbox": true,
        "com.apple.security.network.client": true,
        "com.apple.security.device.audio-input": true,
        "com.apple.security.files.user-selected.read-only": true,
    ]

    /// An entitlements file of the app's, from the test's runfiles.
    static func entitlements(_ name: String) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/applications/visor_macos/\(name)"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static func expectEverywhere(_ entitlements: [String: Any]) {
        for (key, value) in everywhere {
            #expect(entitlements[key] as? Bool == value, "\(key) is \(value)")
        }
    }

    @Test func theBuildToRunHereIsSandboxedAlone() throws {
        let entitlements = try Self.entitlements("app.entitlements")
        Self.expectEverywhere(entitlements)
        // No restricted entitlement: with no profile to allow it, macOS
        // would stop the app at launch.
        #expect(Set(entitlements.keys) == Set(Self.everywhere.keys))
    }

    @Test func ciBuildAddsPushAndItsOwnKeychainGroup() throws {
        let entitlements = try Self.entitlements("app_ci_entitlements.entitlements")
        Self.expectEverywhere(entitlements)
        let extra: Set = ["com.apple.application-identifier", "keychain-access-groups", "com.apple.developer.aps-environment"]
        #expect(Set(entitlements.keys) == Set(Self.everywhere.keys).union(extra))
        #expect(entitlements["com.apple.developer.aps-environment"] as? String == "production")
        // `<team>.<bundle id>`, the team the builder's: one group, the app's own.
        let identifier = try #require(entitlements["com.apple.application-identifier"] as? String)
        let groups = try #require(entitlements["keychain-access-groups"] as? [String])
        #expect(identifier.hasSuffix("." + Self.bundleID) && !identifier.hasPrefix("$("))
        #expect(groups == [identifier])
    }
}

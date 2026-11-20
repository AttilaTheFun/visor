// The app's own keychain access group, read from its signature
// (KeychainSecrets+DataProtection): its `keychain-access-groups` entry for
// the bundle id, else its application identifier; none for a build signed
// without either, which keeps its secrets in the login keychain. "TEAM" is
// a stand-in prefix: no team id is written here.

import Foundation
@testable import VisorServerApple
import XCTest

@MainActor
final class KeychainAccessGroupTests: AppleServerTestCase {
    private let bundle = "com.LoganShire.Visor"

    func testTheGroupNamedForTheBundleIdIsTheOwnOne() {
        XCTAssertEqual(KeychainSecrets.ownGroup(bundleID: bundle, groups: ["TEAM.com.LoganShire.github", "TEAM.com.LoganShire.Visor"],
                                                applicationIdentifier: "TEAM.com.LoganShire.Visor"),
                       "TEAM.com.LoganShire.Visor")
    }

    func testWithNoSuchGroupTheApplicationIdentifierIsTheOwnOne() {
        XCTAssertEqual(KeychainSecrets.ownGroup(bundleID: bundle, groups: [], applicationIdentifier: "TEAM.com.LoganShire.Visor"),
                       "TEAM.com.LoganShire.Visor")
    }

    func testAnotherAppsGroupOrABareBundleIdIsNone() {
        XCTAssertNil(KeychainSecrets.ownGroup(bundleID: bundle, groups: ["TEAM.com.LoganShire.Shireworks", "TEAM.*"],
                                              applicationIdentifier: nil))
        XCTAssertNil(KeychainSecrets.ownGroup(bundleID: bundle, groups: [bundle], applicationIdentifier: bundle))
        XCTAssertNil(KeychainSecrets.ownGroup(bundleID: bundle, groups: ["TEAM.com.LoganShire.Visor.shared"], applicationIdentifier: nil))
    }

    /// This test bundle's own process is signed ad hoc, with no group: the
    /// data-protection store is none, and says why.
    func testAnAdHocProcessHasNoDataProtectionStore() {
        let (store, why) = KeychainSecrets.dataProtection(service: "com.LoganShire.Visor.tests", bundleID: bundle)
        XCTAssertNil(store)
        XCTAssertFalse(why.isEmpty)
    }
}

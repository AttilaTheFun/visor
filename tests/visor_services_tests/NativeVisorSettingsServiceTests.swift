// A native app's launch settings come from its environment as `visor.<key>`
// alone: a bare `account` or `fixture` (a shell's, a container's) is left
// alone. They stand over UserDefaults until the app sets its own.

import Foundation
import Testing
import VisorServices
import VisorServicesNative

@MainActor @Suite struct NativeVisorSettingsServiceTests {
    /// UserDefaults of the test's own, emptied after.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "visor-services-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func bareNamesAreIgnored() throws {
        try withDefaults { defaults in
            let settings = NativeVisorSettingsService(
                environment: ["account": "someone", "fixture": "snapshot", "fixture.screen": "chat", "probe.open": "S1"],
                defaults: defaults)
            for key in VisorLaunchSettings.keys { #expect(settings.get(key: key) == "") }
        }
    }

    @Test func prefixedNamesAreTaken() throws {
        try withDefaults { defaults in
            let settings = NativeVisorSettingsService(
                environment: ["visor.account": "fixture", "visor.fixture": "snapshot", "visor.fixture.screen": "chat",
                              "visor.probe.open": "S1", "visor.fixture.go": "", "fixture": "other"],
                defaults: defaults)
            #expect(settings.get(key: "account") == "fixture")
            #expect(settings.get(key: "fixture") == "snapshot")
            #expect(settings.get(key: "fixture.screen") == "chat")
            #expect(settings.get(key: "probe.open") == "S1")
            // An empty value is none.
            #expect(settings.get(key: "fixture.go") == "")
            // Not a launch setting: never read from the environment.
            let other = NativeVisorSettingsService(environment: ["visor.host": "example"], defaults: defaults)
            #expect(other.get(key: "host") == "")
        }
    }

    @Test func userDefaultsAsBefore() throws {
        try withDefaults { defaults in
            defaults.set("kept", forKey: "visor.account")
            defaults.set("kept-screen", forKey: "visor.fixture.screen")
            let settings = NativeVisorSettingsService(
                environment: ["visor.account": "fixture", "fixture.screen": "chat"], defaults: defaults)
            // The launch's value stands over what was kept; with none (a
            // bare name is none), what was kept is read.
            #expect(settings.get(key: "account") == "fixture")
            #expect(settings.get(key: "fixture.screen") == "kept-screen")
            // What the app sets stands over the launch's, and is kept.
            settings.set(key: "account", value: "mine")
            #expect(settings.get(key: "account") == "mine")
            #expect(defaults.string(forKey: "visor.account") == "mine")
            // Cleared, it is cleared: the launch's doesn't come back.
            settings.set(key: "account", value: "")
            #expect(settings.get(key: "account") == "")
            #expect(defaults.string(forKey: "visor.account") == nil)
        }
    }

    @Test func forgetEverythingClearsSettingsAndSecrets() throws {
        try withDefaults { defaults in
            let settings = NativeVisorSettingsService(environment: ["visor.account": "fixture"], defaults: defaults)
            settings.set(key: "servers", value: "[]")
            settings.setSecret(key: "ssh.key", value: "secret")
            defaults.set("theirs", forKey: "NSWindow Frame main")
            settings.forgetEverything()
            // Every `visor.` setting and secret (a host with no keychain
            // keeps them together), and the launch's: none come back.
            #expect(settings.get(key: "servers") == "")
            #expect(settings.secret(key: "ssh.key") == "")
            #expect(settings.get(key: "account") == "")
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("visor.") }.isEmpty)
            // The rest of the domain stays, unless it is named.
            #expect(defaults.string(forKey: "NSWindow Frame main") == "theirs")
        }
    }

    @Test func ownKeychainGroupIsTheBundlesOwn() {
        let bundle = "com.LoganShire.VisorClient.macOS"
        #expect(VisorKeychainGroup.own(bundleID: bundle, groups: ["T.other", "T." + bundle], applicationIdentifier: nil) == "T." + bundle)
        // None of the groups: the application identifier, if it is the bundle's.
        #expect(VisorKeychainGroup.own(bundleID: bundle, groups: [], applicationIdentifier: "T." + bundle) == "T." + bundle)
        #expect(VisorKeychainGroup.own(bundleID: bundle, groups: ["T.com.LoganShire.Visor"], applicationIdentifier: "T.other") == nil)
        // The bundle id alone is no group, nor another bundle's that ends the same.
        #expect(VisorKeychainGroup.own(bundleID: bundle, groups: [bundle, "T.x" + bundle], applicationIdentifier: nil) == nil)
    }

    @Test func headlessNamesAreTheBareOnes() {
        let environment = ["fixture": "snapshot", "visor.account": "fixture"]
        #expect(VisorLaunchSettings.values(in: environment, prefix: "") == ["fixture": "snapshot"])
        #expect(VisorLaunchSettings.values(in: environment, prefix: VisorLaunchSettings.prefix) == ["account": "fixture"])
    }
}

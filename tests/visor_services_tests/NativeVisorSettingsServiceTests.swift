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

    @Test func headlessNamesAreTheBareOnes() {
        let environment = ["fixture": "snapshot", "visor.account": "fixture"]
        #expect(VisorLaunchSettings.values(in: environment, prefix: "") == ["fixture": "snapshot"])
        #expect(VisorLaunchSettings.values(in: environment, prefix: VisorLaunchSettings.prefix) == ["account": "fixture"])
    }
}

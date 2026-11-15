// The headless client's settings: in memory, for this launch alone, seeded
// from how it was launched, so each test starts as the last did.

import VisorServices

@MainActor
final class LaunchSettingsService: VisorSettingsService {
    /// The settings a launch may give in its environment, by their own
    /// names: the ones Android's launch intent takes as extras
    /// (VisorServices.kt), which Isomer's Android launcher passes a test's
    /// environment as, and the rest of the fixture's.
    static let environmentKeys = [
        "fixture", "fixture.screen", "fixture.appearance", "fixture.orientation", "fixture.go",
        "account", "probe.open",
    ]

    private var values: [String: String] = [:]

    /// `environment`'s settings (`fixture=snapshot`), then `arguments`'
    /// `-visor.<key> <value>` pairs, as the iPhone's launch arguments set
    /// them in UserDefaults (`-visor.fixture snapshot`).
    init(environment: [String: String], arguments: [String]) {
        for key in Self.environmentKeys {
            if let value = environment[key], !value.isEmpty { values[key] = value }
        }
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let next = arguments.index(after: index)
            if argument.hasPrefix("-visor."), next < arguments.endIndex {
                values[String(argument.dropFirst("-visor.".count))] = arguments[next]
                index = arguments.index(after: next)
            } else {
                index = next
            }
        }
    }

    func get(key: String) -> String { values[key] ?? "" }

    func set(key: String, value: String) {
        if value.isEmpty { values[key] = nil } else { values[key] = value }
    }
}

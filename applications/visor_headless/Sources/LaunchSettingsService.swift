// The headless client's settings: in memory, for this launch alone, seeded
// from how it was launched, so each test starts as the last did.

import VisorServices

@MainActor
final class LaunchSettingsService: VisorSettingsService {
    private var values: [String: String] = [:]

    /// `environment`'s settings (VisorLaunchSettings: `fixture=snapshot`,
    /// as Isomer's launchers and Android's launch intent give them), then
    /// `arguments`' `-visor.<key> <value>` pairs, as the iPhone's launch
    /// arguments set them in UserDefaults (`-visor.fixture snapshot`).
    init(environment: [String: String], arguments: [String]) {
        values = VisorLaunchSettings.values(in: environment)
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

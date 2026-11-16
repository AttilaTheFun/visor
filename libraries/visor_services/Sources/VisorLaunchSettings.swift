// The settings a launch may give the client for that launch alone: the
// fixture's and the account's, for screenshot tests and the driver's tests
// (FEATURE_MAP.md). The same names everywhere: the headless client's and
// a headful app's environment (Isomer's launchers pass a test's settings as
// KEY=VALUE, which the iPhone's simulator gets as SIMCTL_CHILD_KEY), the
// iPhone's `-visor.<key> <value>` launch arguments, and Android's launch
// intent's extras (VisorServices.kt lists the same keys).
//
// Nothing secret is among them, and nothing a person's own launch sets:
// an app opened from the home screen, the Dock or a launcher has none of
// these in its environment.

public enum VisorLaunchSettings {
    /// The keys, by the settings' own names.
    public static let keys = [
        "fixture", "fixture.screen", "fixture.appearance", "fixture.orientation", "fixture.go",
        "account", "probe.open",
    ]

    /// The launch settings `environment` gives, by key: `visor.<key>`, or
    /// `<key>` itself; empty values left out.
    public static func values(in environment: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for key in keys {
            if let value = environment["visor." + key] ?? environment[key], !value.isEmpty { values[key] = value }
        }
        return values
    }
}

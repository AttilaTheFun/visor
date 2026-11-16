// The settings a launch may give the client for that launch alone: the
// fixture's and the account's, for screenshot tests and the driver's tests
// (FEATURE_MAP.md). A native app (the iPhone, the Mac, Linux, Windows)
// takes them from its environment as `visor.<key>` alone, the name its
// `-visor.<key> <value>` launch arguments give them (Isomer's launchers
// pass a test's settings as KEY=VALUE, which the iPhone's simulator gets as
// SIMCTL_CHILD_KEY): a bare `account` or `fixture` is too common a name,
// and a native app started from a shell or a container would take whatever
// it inherited. The headless client (test-only) takes them from its
// environment by their own names, and Android from its launch intent's
// extras (VisorServices.kt lists the same keys).
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

    /// What a native app's environment names a setting with, before its
    /// key: `visor.fixture=snapshot`.
    public static let prefix = "visor."

    /// The launch settings `environment` gives, by key, each named
    /// `<prefix><key>` there (a native app's `prefix`, or "" for the
    /// headless client's own names); empty values left out.
    public static func values(in environment: [String: String], prefix: String) -> [String: String] {
        var values: [String: String] = [:]
        for key in keys {
            if let value = environment[prefix + key], !value.isEmpty { values[key] = value }
        }
        return values
    }
}

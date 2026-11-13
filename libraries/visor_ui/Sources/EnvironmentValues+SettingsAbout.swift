// Settings' About section, where the app gives one of its own. Without
// one, Settings shows Visor's own: the version alone.

import SwiftUI

private struct SettingsAboutKey: EnvironmentKey {
    static var defaultValue: AnyView? { nil }
}

extension EnvironmentValues {
    public var settingsAbout: AnyView? {
        get { self[SettingsAboutKey.self] }
        set { self[SettingsAboutKey.self] = newValue }
    }
}

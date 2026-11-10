// Settings' About section, where the app gives one of its own: the
// iPhone's, UpdateKit's version with Install, where its build checks for
// updates (it names an app group). Without one, Settings shows Visor's own:
// the version alone. visor_ui names no update library: it builds on Isomer
// too.

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

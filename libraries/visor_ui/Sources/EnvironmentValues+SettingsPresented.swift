// Whether Settings is open, for the views under VisorRootView that share
// its trailing side: a session's inspector closes as Settings opens, and
// Settings as the session's inspector opens, never both at once.

import SwiftUI

private struct SettingsPresentedKey: EnvironmentKey {
    static var defaultValue: Binding<Bool> { .constant(false) }
}

extension EnvironmentValues {
    var settingsPresented: Binding<Bool> {
        get { self[SettingsPresentedKey.self] }
        set { self[SettingsPresentedKey.self] = newValue }
    }
}

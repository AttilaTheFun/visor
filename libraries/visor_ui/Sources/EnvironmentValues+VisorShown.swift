// Whether Visor is shown at all, as its host says: false while a host's tab
// of it is not the selected one. SwiftUI keeps a hidden tab's views and
// calls no onDisappear on them, so a session's screen left there would keep
// its sync; told it is hidden, it lets the session go as a closed one does
// (AgentServerConnection.leave), and takes it up again when shown.

import SwiftUI

private struct VisorShownKey: EnvironmentKey {
    static var defaultValue: Bool { true }
}

extension EnvironmentValues {
    public var visorShown: Bool {
        get { self[VisorShownKey.self] }
        set { self[VisorShownKey.self] = newValue }
    }
}

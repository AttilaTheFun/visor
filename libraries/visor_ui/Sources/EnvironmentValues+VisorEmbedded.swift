// Whether Visor is shown inside another app (VisorView: Shireworks' Visor
// tab) rather than as its own: there the host owns the window's chrome.

import SwiftUI

private struct VisorEmbeddedKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    var visorEmbedded: Bool {
        get { self[VisorEmbeddedKey.self] }
        set { self[VisorEmbeddedKey.self] = newValue }
    }
}

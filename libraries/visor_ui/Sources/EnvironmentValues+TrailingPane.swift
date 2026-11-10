// The window's one trailing pane (TrailingPane), for the views under
// VisorRootView: a session's page opens its details there, which closes
// Settings, as Settings closes them.

import SwiftUI

private struct TrailingPaneKey: EnvironmentKey {
    static var defaultValue: Binding<TrailingPane?> { .constant(nil) }
}

extension EnvironmentValues {
    var trailingPane: Binding<TrailingPane?> {
        get { self[TrailingPaneKey.self] }
        set { self[TrailingPaneKey.self] = newValue }
    }
}

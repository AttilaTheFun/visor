// Whether the Mac's window is too narrow for the sidebar beside the content
// (NarrowWindow), as VisorRootView measures it: what MacSheetWidth sizes a
// sheet by. False elsewhere.

import SwiftUI

private struct NarrowWindowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var narrowWindow: Bool {
        get { self[NarrowWindowKey.self] }
        set { self[NarrowWindowKey.self] = newValue }
    }
}

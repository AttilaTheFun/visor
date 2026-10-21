// Visor's camera (visor's --//:camera, module VisorCamera) on Isomer:
// the Isomer module's cameraCapture, which every Isomer host answers (the
// system camera on Android, a capture-capable file input on the web, the
// camera picker under a compiled Isomer app's iOS host): a photo written to
// a file Foundation can read, nil when cancelled.

import Foundation
import Isomer
import SwiftUI

public enum Camera {
    /// Every Isomer host offers a camera (a browser without one offers its
    /// file picker instead).
    @MainActor public static var available: Bool { true }
}

extension View {
    /// The seam's modifier is Isomer's in name and shape. Wherever Isomer's is
    /// visible too (a module that imports this one sees Isomer's extensions:
    /// Swift does not hide members of modules imported indirectly) the two
    /// would be ambiguous, so this one gives way, and here it calls Isomer's.
    @_disfavoredOverload
    @MainActor public func cameraCapture(isPresented: Binding<Bool>, onCapture: @escaping (URL?) -> Void) -> some View {
        cameraCapture(isPresented: isPresented, onCapture: onCapture)
    }
}

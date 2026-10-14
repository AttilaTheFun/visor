import Foundation

/// Whether there is a camera to take a photo with: an iPhone's or iPad's,
/// through UIKit's picker; none elsewhere. A host with a camera of its own
/// builds the client with its own library of this module
/// (`--@visor//:camera`), and its own `cameraCapture`.
public enum Camera {
    @MainActor public static var available: Bool {
        #if os(iOS)
        CameraPicker.available
        #else
        false
        #endif
    }
}

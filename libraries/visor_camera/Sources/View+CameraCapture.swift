import Foundation
import SwiftUI

extension View {
    /// The camera, while `isPresented`: the photo taken, written to a
    /// temporary file, or nil when cancelled. Where there is no camera
    /// (`Camera.available`), nothing.
    @MainActor public func cameraCapture(isPresented: Binding<Bool>, onCapture: @escaping (URL?) -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) {
            CameraPicker { data in
                isPresented.wrappedValue = false
                guard let data else { return onCapture(nil) }
                let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("photo-\(UUID().uuidString.prefix(8)).jpg")
                onCapture((try? data.write(to: file)) != nil ? file : nil)
            }
            .ignoresSafeArea()
        }
        #else
        self
        #endif
    }
}

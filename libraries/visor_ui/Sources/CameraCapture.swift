import AgentUI
import SwiftUI

#if os(iOS)
import UIKit

/// The camera, for a photo to attach. SwiftUI has no camera of its own,
/// so this is the one place the app reaches for UIKit's picker. Hands
/// back the photo as JPEG, or nil when cancelled.
struct CameraCapture: UIViewControllerRepresentable {
    let done: (Data?) -> Void

    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (Data?) -> Void
        init(done: @escaping (Data?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.85))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
#endif

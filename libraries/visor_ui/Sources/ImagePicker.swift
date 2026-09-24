// Picking a picture to send. A phone opens its photo library, a Mac
// opens a panel; the portable SwiftUI has neither, so the button that
// leads here is not offered there. What comes back is the bytes and a
// name — the upload and the path are the caller's business.

import SwiftUI
#if os(iOS)
import PhotosUI
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A picture chosen but not yet sent: the bytes for the thumbnail, the
/// name to give it on the computer, and the path once it is there.
struct PickedImage: Identifiable, Equatable {
    let id: String
    let name: String
    let base64: String
    var path: String?

    init(name: String, base64: String) {
        self.id = name + "-" + String(base64.prefix(16))
        self.name = name
        self.base64 = base64
    }
}

extension View {
    /// Whether this host can pick a picture at all.
    static var canPickImages: Bool {
        #if os(iOS) || os(macOS)
        true
        #else
        false
        #endif
    }

    @ViewBuilder func imagePicker(isPresented: Binding<Bool>, onPick: @escaping ([PickedImage]) -> Void) -> some View {
        #if os(iOS)
        modifier(PhotoPickerModifier(isPresented: isPresented, onPick: onPick))
        #elseif os(macOS)
        onChange(of: isPresented.wrappedValue) { open in
            guard open else { return }
            isPresented.wrappedValue = false
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff]
            guard panel.runModal() == .OK else { return }
            let picked = panel.urls.compactMap { url -> PickedImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return PickedImage(name: url.lastPathComponent, base64: data.base64EncodedString())
            }
            if !picked.isEmpty { onPick(picked) }
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// The photo library, and the wait for the bytes behind each choice.
private struct PhotoPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: ([PickedImage]) -> Void
    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $selection, maxSelectionCount: 4, matching: .images)
            .onChange(of: selection) { items in
                guard !items.isEmpty else { return }
                Task {
                    var picked: [PickedImage] = []
                    for (index, item) in items.enumerated() {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let name = (item.itemIdentifier ?? "image-\(index)")
                            .replacingOccurrences(of: "/", with: "-") + ".png"
                        picked.append(PickedImage(name: name, base64: data.base64EncodedString()))
                    }
                    selection = []
                    if !picked.isEmpty { onPick(picked) }
                }
            }
    }
}
#endif

// Picking something to send: files anywhere, and on a phone the photo
// library and the camera; or files dropped on the chat. All standard
// SwiftUI, which the portable SwiftUI implements too; only the camera,
// which SwiftUI has none of, is a helper (Compat.swift on iOS,
// Isomer's own elsewhere). What comes back is the bytes and a
// name — the upload and the path are the caller's business.

import Foundation
import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if os(iOS) || os(macOS)
import AVFoundation
import ImageIO
#endif

extension View {
    /// Whether this host offers a choice of camera, photo library and
    /// files (a phone), rather than going straight to files (a Mac, a
    /// browser).
    static var offersAttachMenu: Bool {
        #if os(macOS) || arch(wasm32)
        false
        #else
        true
        #endif
    }

    /// Whether there is a camera to take a photo with.
    static var canTakePhotos: Bool {
        #if os(iOS)
        CameraCapture.available
        #elseif os(macOS)
        false
        #else
        true
        #endif
    }

    /// The pickers behind the attach button, one per source; `source` is
    /// the one open, and goes back to nil when it closes.
    func attachmentPickers(_ source: Binding<AttachSource?>, onPick: @escaping ([PickedImage]) -> Void) -> some View {
        modifier(AttachmentPickers(source: source, onPick: onPick))
    }

    /// Files dropped here are attached as if picked.
    @ViewBuilder func attachmentDrop(onPick: @escaping ([PickedImage]) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        dropDestination(for: URL.self) { urls, _ in
            let picked = PickedImage.read(urls)
            if !picked.isEmpty { onPick(picked) }
            return !picked.isEmpty
        }
        #endif
    }
}

/// Files everywhere; the photo library and the camera where there are
/// such things.
private struct AttachmentPickers: ViewModifier {
    @Binding var source: AttachSource?
    let onPick: ([PickedImage]) -> Void
    #if os(iOS)
    @State private var selection: [PhotosPickerItem] = []
    #endif

    private func open(_ which: AttachSource) -> Binding<Bool> {
        Binding(get: { source == which }, set: { if !$0, source == which { source = nil } })
    }

    func body(content: Content) -> some View {
        #if os(tvOS)
        // A TV picks nothing: no files, no library, no camera.
        content
        #else
        content
            .fileImporter(isPresented: open(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                let picked = PickedImage.read((try? result.get()) ?? [])
                if !picked.isEmpty { onPick(picked) }
            }
            #if os(iOS)
            .photosPicker(isPresented: open(.library), selection: $selection, maxSelectionCount: 4,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    var picked: [PickedImage] = []
                    for (index, item) in items.enumerated() {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        picked.append(PickedImage(name: Self.name(of: item, index: index), base64: data.base64EncodedString()))
                    }
                    selection = []
                    if !picked.isEmpty { onPick(picked) }
                }
            }
            .cameraCapture(isPresented: open(.camera)) { url in
                source = nil
                if let url { onPick(PickedImage.read([url])) }
            }
            #endif
        #endif
    }

    #if os(iOS)
    /// What to call a photo or video from the library on the computer.
    private static func name(of item: PhotosPickerItem, index: Int) -> String {
        #if os(iOS)
        // The library's own id is no file name: a video keeps its own
        // kind, a picture goes as a PNG name.
        let movie = item.supportedContentTypes.first { $0.conforms(to: .movie) }
        let ext = movie.map { $0.preferredFilenameExtension ?? "mov" } ?? "png"
        return (item.itemIdentifier ?? (movie == nil ? "image-\(index)" : "video-\(index)"))
            .replacingOccurrences(of: "/", with: "-") + "." + ext
        #else
        // The portable picker names the item as its file.
        return item.itemIdentifier ?? "image-\(index).png"
        #endif
    }
    #endif
}

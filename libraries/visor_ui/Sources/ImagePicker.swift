// Picking a picture or a video to send. A phone opens its photo library, a Mac
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
#if os(iOS) || os(macOS)
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
#endif

/// A picture or video chosen but not yet sent: the bytes, the name to
/// give it on the computer, and the path once it is there.
struct PickedImage: Identifiable, Equatable {
    let id: String
    let name: String
    let base64: String
    var path: String?
    /// For a video, a frame of it as a PNG, base64: what the tile shows.
    var thumbnail: String?

    var isVideo: Bool { AttachmentKind.isVideo(name) }

    init(name: String, base64: String) {
        self.id = name + "-" + String(base64.prefix(16))
        self.name = name
        self.base64 = base64
        if AttachmentKind.isVideo(name) { thumbnail = VideoThumbnail.png(videoBase64: base64, name: name) }
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
            panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff, .movie]
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
            .photosPicker(isPresented: $isPresented, selection: $selection, maxSelectionCount: 4,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: selection) { items in
                guard !items.isEmpty else { return }
                Task {
                    var picked: [PickedImage] = []
                    for (index, item) in items.enumerated() {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        // A video keeps its own kind; a picture goes as a PNG name.
                        let movie = item.supportedContentTypes.first { $0.conforms(to: .movie) }
                        let ext = movie.map { $0.preferredFilenameExtension ?? "mov" } ?? "png"
                        let name = (item.itemIdentifier ?? (movie == nil ? "image-\(index)" : "video-\(index)"))
                            .replacingOccurrences(of: "/", with: "-") + "." + ext
                        picked.append(PickedImage(name: name, base64: data.base64EncodedString()))
                    }
                    selection = []
                    if !picked.isEmpty { onPick(picked) }
                }
            }
    }
}
#endif

/// What an attachment is, by its name.
enum AttachmentKind {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "webm", "mkv"]

    static func isVideo(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// A frame from near the start of a video, as a PNG in base64.
enum VideoThumbnail {
    static func png(videoBase64: String, name: String) -> String? {
        #if os(iOS) || os(macOS)
        guard let data = Data(base64Encoded: videoBase64) else { return nil }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + "-" + name)
        guard (try? data.write(to: file)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        guard let frame = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data).base64EncodedString()
        #else
        return nil
        #endif
    }
}

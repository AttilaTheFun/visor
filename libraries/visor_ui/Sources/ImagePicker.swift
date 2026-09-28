// Picking something to send: files anywhere, and on a phone the photo
// library and the camera; or files dropped on the chat. The portable
// SwiftUI has none of these yet, so the button that leads here is not
// offered there. What comes back is the bytes and a name — the upload
// and the path are the caller's business.

import SwiftUI
#if os(iOS)
import PhotosUI
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

/// Where an attachment comes from.
enum AttachSource: Identifiable {
    case camera, library, files
    var id: Self { self }
}

extension View {
    /// Whether this host can pick files at all.
    static var canPickFiles: Bool {
        #if os(iOS) || os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether this host offers a choice of camera, photo library and
    /// files (a phone), rather than going straight to files (a Mac).
    static var offersAttachMenu: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The pickers behind the attach button, one per source; `source` is
    /// the one open, and goes back to nil when it closes.
    @ViewBuilder func attachmentPickers(_ source: Binding<AttachSource?>, onPick: @escaping ([PickedImage]) -> Void) -> some View {
        #if os(iOS) || os(macOS)
        modifier(AttachmentPickers(source: source, onPick: onPick))
        #else
        self
        #endif
    }

    /// Files dropped here are attached as if picked.
    @ViewBuilder func attachmentDrop(onPick: @escaping ([PickedImage]) -> Void) -> some View {
        #if os(iOS) || os(macOS)
        dropDestination(for: URL.self) { urls, _ in
            let picked = PickedImage.read(urls)
            if !picked.isEmpty { onPick(picked) }
            return !picked.isEmpty
        }
        #else
        self
        #endif
    }
}

#if os(iOS) || os(macOS)
extension PickedImage {
    /// The files behind some URLs, read (with the access a picker or a
    /// drop grants a file outside the app's own).
    static func read(_ urls: [URL]) -> [PickedImage] {
        urls.compactMap { url in
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return PickedImage(name: url.lastPathComponent, base64: data.base64EncodedString())
        }
    }
}

/// Files everywhere; on a phone the photo library and the camera too.
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
        content
            .fileImporter(isPresented: open(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                let picked = PickedImage.read((try? result.get()) ?? [])
                if !picked.isEmpty { onPick(picked) }
            }
            #if os(iOS)
            .photosPicker(isPresented: open(.library), selection: $selection, maxSelectionCount: 4,
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
            .fullScreenCover(isPresented: open(.camera)) {
                CameraCapture { data in
                    source = nil
                    if let data { onPick([PickedImage(name: "photo.jpg", base64: data.base64EncodedString())]) }
                }
                .ignoresSafeArea()
            }
            #endif
    }
}
#endif

/// What an attachment is, by its name.
enum AttachmentKind {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "webm", "mkv"]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]

    /// A picture, shown as one; anything else that is not a video is a
    /// file, shown by its name.
    static func isImage(_ name: String) -> Bool {
        imageExtensions.contains(pathExtension(of: name).lowercased())
    }

    static func isVideo(_ name: String) -> Bool {
        videoExtensions.contains(pathExtension(of: name).lowercased())
    }

    /// The last component of a path. The standard library alone: this
    /// builds for the browser, whose Foundation has no NSString.
    static func fileName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// The extension of a path's last component, without the dot.
    static func pathExtension(of path: String) -> String {
        let name = fileName(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
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

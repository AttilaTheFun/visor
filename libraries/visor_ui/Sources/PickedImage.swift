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

/// A picture or video chosen but not yet sent: the bytes, the name to
/// give it on the computer, and the path once it is there.
struct PickedImage: Identifiable, Equatable {
    let id: String
    let name: String
    let base64: String
    var path: String?
    /// For a video, a frame of it as a PNG, base64: what the tile shows.
    /// Made once the video is picked (`VideoThumbnail`).
    var thumbnail: String?

    var isVideo: Bool { AttachmentKind.isVideo(name) }

    init(name: String, base64: String) {
        self.id = name + "-" + String(base64.prefix(16))
        self.name = name
        self.base64 = base64
    }
}

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

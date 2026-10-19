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

    /// Its own id each time it is picked: the id is also its thumbnail's
    /// key in the image cache, and one made of its name and first bytes
    /// was the same for every "image-0.png" (a PNG's first bytes are its
    /// signature), so a new picture showed an earlier one's thumbnail.
    init(name: String, base64: String) {
        self.id = UUID().uuidString
        self.name = name
        self.base64 = base64
    }
}

extension PickedImage {
    /// The files behind some URLs, read (with the access a picker or a
    /// drop grants a file outside the app's own).
    static func read(_ urls: [URL]) -> [PickedImage] {
        urls.compactMap { url in
            // Security-scoped access is Apple's sandbox, and Apple's
            // Foundation alone has it.
            #if canImport(Darwin)
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            #endif
            guard let data = try? Data(contentsOf: url) else { return nil }
            return PickedImage(name: url.lastPathComponent, base64: data.base64EncodedString())
        }
    }
}

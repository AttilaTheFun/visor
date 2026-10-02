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

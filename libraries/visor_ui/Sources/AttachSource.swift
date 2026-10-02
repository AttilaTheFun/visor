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

/// Where an attachment comes from.
enum AttachSource: Identifiable {
    case camera, library, files
    var id: Self { self }
}

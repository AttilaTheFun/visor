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

/// A frame from near the start of a video, as a PNG in base64. Made off
/// the main actor: the video is written out and decoded to get it.
enum VideoThumbnail {
    static func png(videoBase64: String, name: String) async -> String? {
        #if os(iOS) || os(macOS)
        guard let data = Data(base64Encoded: videoBase64) else { return nil }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + "-" + name)
        guard (try? data.write(to: file)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        guard let frame = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image else { return nil }
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

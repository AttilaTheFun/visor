import AgentUI
import Foundation
import ImageIO
import SwiftUI

/// A picture decoded off the main actor, no larger than it is drawn: what
/// a view shows is already a bitmap, so drawing it costs nothing more.
struct DecodedPicture: Sendable {
    let image: CGImage
    /// The picture's own size, upright, in pixels — what the transcript
    /// reserved its frame from, whatever size it was decoded at.
    let size: CGSize

    /// Decodes base64 bytes for drawing at `maxEdge` points (0 for as large
    /// as the picture is) on a display of `scale`, off the main actor.
    static func decode(base64: String, maxEdge: CGFloat, scale: CGFloat) async -> DecodedPicture? {
        await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: base64),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0
            else { return nil }
            // Orientations 5–8 are turned a quarter: the upright picture's
            // width is the stored height.
            let turned = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            let size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            let drawn = TranscriptMetrics.fitted(size, maxEdge: maxEdge) ?? size
            let longest = max(size.width, size.height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(min(max(drawn.width, drawn.height) * scale, longest).rounded(.up)),
                kCGImageSourceCreateThumbnailWithTransform: true,
                // Decoded here, not on the first draw.
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return DecodedPicture(image: image, size: size)
        }.value
    }
}

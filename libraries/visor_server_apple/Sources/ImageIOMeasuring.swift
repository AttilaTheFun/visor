import Foundation
import ImageIO
import VisorProtocol
import VisorServer

/// Pictures' sizes from ImageIO, which reads every format the system
/// knows, from the header alone.
public struct ImageIOMeasuring: ImageMeasuring {
    public init() {}

    public func pixelSize(path: String) -> ImageSize? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        // A picture that says it is rotated is shown rotated: swap so the
        // layout reserves the shape the eye will see.
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? ImageSize(width: height, height: width) : ImageSize(width: width, height: height)
    }
}

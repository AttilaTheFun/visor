import VisorProtocol

/// A picture's size in pixels, as it is shown (turned upright), read from
/// its header without decoding it.
public protocol ImageMeasuring: Sendable {
    /// Nil for a file that is not there or not a picture.
    func pixelSize(path: String) -> ImageSize?
}

import AgentUI
import SwiftUI

#if os(iOS)
import UIKit
#endif

/// A picture from base64 bytes. Apple decodes them; the portable SwiftUI
/// hands the browser a data URL, which is the one thing every browser
/// already knows how to draw.
@MainActor
struct Base64Image: View {
    let base64: String
    /// The longest side it may take; 0 for as much room as there is. A
    /// picture is given exactly its own shape at that size, so nothing
    /// around it is empty box — which is what left tall screenshots
    /// floating in the middle and the rounded corner clipping nothing.
    var maxEdge: CGFloat = 0

    /// The size to draw at, from the picture's own and the room allowed —
    /// the transcript's rule, so the frame it reserved from the size it
    /// knew in advance is exactly the frame the picture takes.
    private func size(for pixels: CGSize) -> CGSize? {
        TranscriptMetrics.fitted(pixels, maxEdge: maxEdge)
    }

    var body: some View {
        // The picture's own proportions go on the view, so a frame around
        // it hugs the picture instead of letterboxing it — otherwise a
        // rounded corner is cut off empty space and never shows.
        #if os(iOS)
        if let data = Data(base64Encoded: base64), let image = UIImage(data: data) {
            drawn(Image(uiImage: image), pixels: image.size)
        } else {
            Color.secondary.opacity(0.15)
        }
        #elseif os(macOS)
        if let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            drawn(Image(nsImage: image), pixels: image.size)
        } else {
            Color.secondary.opacity(0.15)
        }
        #else
        // A browser keeps a picture's proportions under a maximum rather
        // than padding it out to a box, so the limit can go straight on.
        AsyncImage(url: URL(string: "data:image/png;base64," + base64)) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            Color.secondary.opacity(0.15)
        }
        .frame(maxWidth: maxEdge > 0 ? maxEdge : nil, maxHeight: maxEdge > 0 ? maxEdge : nil)
        #endif
    }

    #if os(iOS) || os(macOS)
    /// At exactly its own shape when a size was asked for, and filling
    /// what it is given when one was not.
    @ViewBuilder private func drawn(_ image: Image, pixels: CGSize) -> some View {
        if let size = size(for: pixels) {
            image.resizable().frame(width: size.width, height: size.height)
        } else {
            image.resizable().aspectRatio(pixels.width / max(pixels.height, 1), contentMode: .fit)
        }
    }
    #endif
}

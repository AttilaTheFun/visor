import AgentUI
import SwiftUI

/// A picture from base64 bytes, decoded off the main actor at the size it
/// is drawn and kept, so drawing it again (the row rebuilt, scrolled back
/// to, the composer redrawn as you type) is only drawing.
@MainActor
struct Base64Image: View {
    let base64: String
    /// What names these bytes: the cache's key for them, so they are not
    /// compared or hashed, which for a photo is megabytes.
    let key: String
    /// The longest side it may take; 0 for as much room as there is. A
    /// picture is given exactly its own shape at that size, so nothing
    /// around it is empty box — which is what left tall screenshots
    /// floating in the middle and the rounded corner clipping nothing.
    var maxEdge: CGFloat = 0
    @Environment(\.displayScale) private var scale
    /// The last picture decoded here, under the key it was decoded for.
    @State private var decoded: (key: String, picture: DecodedPicture)?
    @State private var failed = false

    /// The cache's key for the bitmap: the bytes at one drawn size.
    private var pictureKey: String { "\(key)@\(Int(maxEdge))x\(Int(scale))" }

    var body: some View {
        // From the cache when it has it, so a rebuilt row draws in its
        // first frame instead of its placeholder.
        let wanted = pictureKey
        if let picture = decoded?.key == wanted ? decoded?.picture : VisorImageCache.shared.picture(for: wanted) {
            drawn(picture)
        } else {
            Color.secondary.opacity(failed ? 0.15 : 0.1)
                .task(id: wanted) { await decode() }
        }
    }

    /// The picture's own proportions go on the view, so a frame around it
    /// hugs the picture instead of letterboxing it — otherwise a rounded
    /// corner is cut off empty space and never shows. At exactly its own
    /// shape when a size was asked for (the transcript's rule, so the frame
    /// it reserved from the size it knew is the frame the picture takes),
    /// and filling what it is given when one was not.
    @ViewBuilder private func drawn(_ picture: DecodedPicture) -> some View {
        let image = Image(picture.image, scale: scale, label: Text(""))
        if let size = TranscriptMetrics.fitted(picture.size, maxEdge: maxEdge) {
            image.resizable().frame(width: size.width, height: size.height)
        } else {
            image.resizable().aspectRatio(picture.size.width / max(picture.size.height, 1), contentMode: .fit)
        }
    }

    private func decode() async {
        let wanted = pictureKey
        guard let picture = await DecodedPicture.decode(base64: base64, maxEdge: maxEdge, scale: scale) else {
            failed = true
            return
        }
        VisorImageCache.shared.put(picture, for: wanted)
        decoded = (wanted, picture)
    }
}

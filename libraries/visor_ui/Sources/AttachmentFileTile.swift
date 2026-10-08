import AgentUI
import SwiftUI

/// An attachment that is not a picture, in a thread: a video or a file,
/// drawn as a tile with its glyph and name, without fetching it. Tapped,
/// the thread fetches it and the system's preview plays or opens it.
struct AttachmentFileTile: View {
    let name: String
    let isVideo: Bool

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            VStack(spacing: 6) {
                Image(systemName: isVideo ? "play.circle.fill" : "doc.fill")
                    .font(.title)
                    .foregroundColor(isVideo ? .white : .secondary)
                    .shadow(radius: isVideo ? 2 : 0)
                Text(name)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
            .padding(8)
        }
        .frame(width: 160, height: 100)
        .accessibilityLabel(isVideo ? "Video \(name)" : "File \(name)")
    }
}

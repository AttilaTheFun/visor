// Pictures in a transcript live on the computer, not here: a screenshot
// the agent took is a file in its own support directory. A row names the
// file; this fetches the bytes over the same authenticated connection
// everything else uses, and keeps them so scrolling past twice costs one
// request.

import AgentUI
import SwiftUI
#if os(iOS) || os(macOS)
import Foundation
#endif
import VisorClient

/// An attachment the transcript named, on the computer that holds it: a
/// picture fetched and drawn; a video or a file named on a tile, fetched
/// only when opened. The reference is "<computer id>|<path>", because
/// the transcript's image hook is one closure for the whole app and has
/// to be told which machine to ask.
@MainActor
struct VisorImage: View {
    let reference: String
    /// The longest side it may take; 0 for as much room as there is.
    var maxEdge: CGFloat = 0
    var store: VisorStore
    @State private var base64: String?
    @State private var failed = false

    private var serverID: String { String(reference.split(separator: "|", maxSplits: 1).first ?? "") }
    private var path: String { String(reference.split(separator: "|", maxSplits: 1).dropFirst().first ?? "") }

    var body: some View {
        Group {
            if !AttachmentKind.isImage(path) {
                AttachmentFileTile(name: AttachmentKind.fileName(path), isVideo: AttachmentKind.isVideo(path))
            } else if let base64 {
                Base64Image(base64: base64, key: reference, maxEdge: maxEdge)
            } else if failed {
                // Nothing to show and nothing to be done about it here:
                // the file is on a computer that is not answering, or is
                // gone from it.
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "photo").foregroundColor(.secondary)
                }
                .frame(width: 120, height: 90)
            } else {
                // While the bytes are on their way: fills the frame the
                // transcript reserved from the picture's known size, so
                // the row is already its final shape; a picture of unknown
                // size gets a modest box of its own.
                ZStack {
                    Color.secondary.opacity(0.1)
                    ProgressView().controlSize(.small)
                }
                .frame(minWidth: 120, minHeight: 90)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: reference) { if AttachmentKind.isImage(path) { await load() } }
    }

    #if os(iOS) || os(macOS)
    /// The bytes behind a reference, for the system's preview and the
    /// share sheet. A picture's are kept with the others drawn; a video's
    /// or a file's (megabytes, shown once) are not.
    static func bytes(reference: String, store: VisorStore) async -> Data? {
        let parts = reference.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let host = store.server(for: String(parts[0])) else { return nil }
        let path = String(parts[1])
        let base64: String
        if let cached = VisorImageCache.shared.data(for: reference) {
            base64 = cached
        } else if let fetched = try? await host.fileData(path: path) {
            if AttachmentKind.isImage(path) { VisorImageCache.shared.put(fetched, for: reference) }
            base64 = fetched
        } else {
            return nil
        }
        return Data(base64Encoded: base64)
    }
    #endif

    private func load() async {
        if let cached = VisorImageCache.shared.data(for: reference) {
            base64 = cached
            return
        }
        guard let host = store.server(for: serverID), !path.isEmpty else { failed = true; return }
        do {
            let data = try await host.fileData(path: path)
            VisorImageCache.shared.put(data, for: reference)
            base64 = data
        } catch {
            failed = true
        }
    }
}

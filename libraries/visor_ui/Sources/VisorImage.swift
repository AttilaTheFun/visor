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

/// A picture the transcript named, fetched from the computer that holds
/// it. The reference is "<computer id>|<path>", because the transcript's
/// image hook is one closure for the whole app and has to be told which
/// machine to ask.
@MainActor
struct VisorImage: View {
    let reference: String
    /// The longest side it may take; 0 for as much room as there is.
    var maxEdge: CGFloat = 0
    @ObservedObject var store: VisorStore
    #if os(iOS) || os(macOS)
    @State private var base64: String?
    #else
    /// The picture, handed to the portable SwiftUI's host once (decoded
    /// there off the main thread) and drawn by this short URL; the view
    /// itself never holds the bytes.
    @State private var source: URL?
    #endif
    @State private var failed = false

    private var serverID: String { String(reference.split(separator: "|", maxSplits: 1).first ?? "") }
    private var path: String { String(reference.split(separator: "|", maxSplits: 1).dropFirst().first ?? "") }

    var body: some View {
        Group {
            #if os(iOS) || os(macOS)
            if let base64 {
                Base64Image(base64: base64, maxEdge: maxEdge)
            } else if failed {
                missing
            } else {
                loading
            }
            #else
            if let source {
                AsyncImage(url: source) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    loading
                }
                .frame(maxWidth: maxEdge > 0 ? maxEdge : nil, maxHeight: maxEdge > 0 ? maxEdge : nil)
            } else if failed {
                missing
            } else {
                loading
            }
            #endif
        }
        .task(id: reference) { await load() }
    }

    /// Nothing to show and nothing to be done about it here: the file is on
    /// a computer that is not answering, or is gone from it.
    private var missing: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "photo").foregroundColor(.secondary)
        }
        .frame(width: 120, height: 90)
    }

    /// While the bytes are on their way: fills the frame the transcript
    /// reserved from the picture's known size, so the row is already its
    /// final shape; a picture of unknown size gets a modest box of its own.
    private var loading: some View {
        ZStack {
            Color.secondary.opacity(0.1)
            ProgressView().controlSize(.small)
        }
        .frame(minWidth: 120, minHeight: 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(iOS) || os(macOS)
    /// The bytes behind a reference, for the viewer's share sheet.
    static func bytes(reference: String, store: VisorStore) async -> Data? {
        let parts = reference.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let host = store.server(for: String(parts[0])) else { return nil }
        let base64: String
        if let cached = VisorImageCache.shared.data(for: reference) {
            base64 = cached
        } else if let fetched = try? await host.fileData(path: String(parts[1])) {
            VisorImageCache.shared.put(fetched, for: reference)
            base64 = fetched
        } else {
            return nil
        }
        return Data(base64Encoded: base64)
    }
    #endif

    private func load() async {
        #if os(iOS) || os(macOS)
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
        #else
        // Handed over once per picture: the URL stands for it from then on,
        // in this row and any other that shows the same file.
        let key = Self.key(for: reference)
        if IsomerImages.isRegistered(key) {
            source = URL(string: IsomerImages.url(for: key))
            return
        }
        guard let host = store.server(for: serverID), !path.isEmpty else { failed = true; return }
        do {
            let base64 = try await host.fileData(path: path)
            // The bytes are read off the main actor; the host decodes them
            // off the main thread too, scaled to the screen.
            let bytes = await Task.detached(priority: .userInitiated) {
                Self.decodeBase64(base64)
            }.value
            guard let bytes, !bytes.isEmpty else { failed = true; return }
            source = IsomerImages.register(bytes, key: key)
        } catch {
            failed = true
        }
        #endif
    }

    #if !(os(iOS) || os(macOS))
    /// A short, URL-safe name for a reference (FNV-1a over its bytes): the
    /// reference itself holds a path and a "|".
    nonisolated static func key(for reference: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in reference.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "visor-" + String(hash, radix: 16)
    }

    /// Base64 to bytes (standard alphabet; whitespace and padding skipped).
    nonisolated static func decodeBase64(_ text: String) -> [UInt8]? {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, byte) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            table[Int(byte)] = UInt8(index)
        }
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 3 / 4)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in text.utf8 {
            let value = table[Int(byte)]
            if value == 0xFF {
                if byte == UInt8(ascii: "=") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: " ") { continue }
                return nil
            }
            buffer = buffer << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return out
    }
    #endif
}

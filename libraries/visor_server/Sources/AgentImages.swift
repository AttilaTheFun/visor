// Pictures that pass through a session: a screenshot the agent took, an
// image it was shown, a file the user attached from a phone. They arrive
// as base64 and are far too big to sit in a transcript, so they are
// written down and everything afterwards refers to the path. The client
// asks for the bytes again when it draws them.

import Foundation
import VisorProtocol

enum AgentImages {
    /// Where pictures live: beside the session store, so removing Visor's
    /// data directory takes them with it.
    static var directory: URL {
        let base = ServerPlatform.current.host.dataDirectory.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Writes base64 bytes down and returns the path, or nil if they were
    /// not bytes at all.
    static func save(base64: String, mediaType: String?, name: String? = nil) -> String? {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        // Named by its bytes: the same picture read again from the
        // session file is the same file, not a second copy.
        let digest = SHA256.hash(data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let suffix = fileExtension(for: mediaType)
        // A given name keeps its stem but takes the digest too: a phone
        // names every pick "image-0", and two pictures are two files.
        let filename: String
        if let name {
            let clean = sanitised(name)
            let stem = (clean as NSString).deletingPathExtension
            let ext = (clean as NSString).pathExtension
            filename = "\(stem.isEmpty ? "image" : stem)-\(digest).\(ext.isEmpty ? suffix : ext)"
        } else {
            filename = "\(digest).\(suffix)"
        }
        let file = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: file.path) { return file.path }
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file.path
    }

    /// The bytes of a file a transcript names (a picture the agent made
    /// or was shown, wherever it is; something the user attached), base64
    /// for the wire. Whoever may ask is already let in to the computer's
    /// sessions; the size is what is limited.
    static func read(path: String) -> String? {
        let resolved = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else { return nil }
        // A picture, not a payload: enough for a screenshot of a large
        // display, and small enough that a phone on a slow link survives.
        guard data.count <= 24 * 1024 * 1024 else { return nil }
        return data.base64EncodedString()
    }

    /// A picture's size in pixels, read from its header — the bytes are
    /// not decoded. Nil for a file that is not there or not a picture.
    static func pixelSize(path: String) -> ImageSize? {
        ServerPlatform.current.images.pixelSize(path: (path as NSString).expandingTildeInPath)
    }

    /// Sizes for a row's pictures, in order; stops at the first one that
    /// cannot be read, so the list is always a prefix of `images`.
    static func pixelSizes(paths: [String]) -> [ImageSize] {
        var sizes: [ImageSize] = []
        for path in paths {
            guard let size = pixelSize(path: path) else { break }
            sizes.append(size)
        }
        return sizes
    }

    private static func fileExtension(for mediaType: String?) -> String {
        switch mediaType {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "png"
        }
    }

    /// A name that cannot climb out of the directory it is written into.
    private static func sanitised(_ name: String) -> String {
        let safe = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character : "-"
        }
        let text = String(safe)
        return text.isEmpty || text.hasPrefix(".") ? "image.png" : text
    }
}

import Foundation

extension PickedImage {
    /// The picked bytes as a file beside the temporary files, under their
    /// own name, for the system's preview of what is about to be sent.
    func temporaryFile() -> URL? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return nil }
        return destination
    }
}

import ClaudeTranscript
import Foundation

/// The kernel's word on a file, through a dispatch source on its vnode:
/// written to, extended, deleted or renamed.
public struct DispatchFileWatching: FileWatching {
    public init() {}

    public func changes(to url: URL) -> AsyncStream<Bool>? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .global(qos: .utility))
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            source.setEventHandler {
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    continuation.yield(false)
                    continuation.finish()
                } else {
                    continuation.yield(true)
                }
            }
            source.setCancelHandler { close(descriptor) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}

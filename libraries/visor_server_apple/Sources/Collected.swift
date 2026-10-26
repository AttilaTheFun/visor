import Foundation
import Synchronization

/// What a command wrote, gathered as it arrives on a queue of its own.
final class Collected: Sendable {
    private let data = Mutex(Data())

    func append(_ chunk: Data) { data.withLock { $0.append(chunk) } }

    var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
}

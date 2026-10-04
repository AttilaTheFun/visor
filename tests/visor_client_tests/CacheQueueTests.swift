// The message cache is written off the main actor, in the order it was
// asked, and a read sees every write asked for before it: a sync's or a
// page's hundreds of rows never hold up a frame.

import Foundation
import Synchronization
@testable import VisorClient
import XCTest

@MainActor
final class CacheQueueTests: XCTestCase {
    func testJobsRunOffTheMainThreadInOrder() async {
        let queue = CacheQueue()
        let log = Mutex<[String]>([])
        for index in 0..<50 {
            queue.write {
                let main = Thread.isMainThread
                log.withLock { $0.append(main ? "main" : "\(index)") }
            }
        }
        let seen = await queue.read { log.withLock { $0 } }
        XCTAssertEqual(seen, (0..<50).map(String.init), "every write, in order, none on the main thread")
    }
}

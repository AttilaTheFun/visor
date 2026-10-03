import Foundation
@testable import VisorClient
import VisorServices
import XCTest

@MainActor
final class ConnectionLogTests: XCTestCase {
    /// The time on each line is the device's own, to the millisecond.
    func testTheStampIsLocalTime() {
        let time = 1_791_051_731.25
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        XCTAssertEqual(ConnectionLog.stamp(time), formatter.string(from: Date(timeIntervalSince1970: time)))
    }

    /// The export says which zone its times are in.
    func testTheHeaderNamesTheZone() {
        XCTAssertEqual(ConnectionLog.header(offset: 0), "Visor connection log. Times are UTC.")
        XCTAssertEqual(ConnectionLog.header(offset: -14_400), "Visor connection log. Times are UTC-04:00.")
        XCTAssertEqual(ConnectionLog.header(offset: 19_800), "Visor connection log. Times are UTC+05:30.")
        XCTAssertTrue(ConnectionLog().text.hasPrefix("Visor connection log. Times are UTC"))
    }

    /// The newest lines are kept, and the next run reads them back.
    func testTheNewestAreKeptAcrossRuns() {
        let settings = MemorySettings()
        VisorHost.settings = settings
        let log = ConnectionLog()
        log.now = { 0 }
        for index in 0..<(ConnectionLog.limit + 5) { log.note("Mini", "line \(index)") }
        XCTAssertEqual(log.lines.count, ConnectionLog.limit)
        XCTAssertTrue(log.lines.first?.hasSuffix("Mini: line 5") ?? false)
        log.keep()
        let next = ConnectionLog()
        next.note("app", "in front")
        XCTAssertEqual(next.lines.count, ConnectionLog.limit, "the last run's lines, then this one's, the newest kept")
        XCTAssertTrue(next.lines.first?.hasSuffix("Mini: line 6") ?? false)
        XCTAssertTrue(next.text.hasSuffix("app: in front\n"))
    }
}

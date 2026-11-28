// One SSH connection's channels, held under the computer's limit: past it
// a connection waits its turn rather than being refused and closed with
// what it carried (26 Nov 2026).

@testable import VisorSSH
import XCTest

final class ChannelGateTests: XCTestCase {
    func testPastTheLimitAConnectionWaitsItsTurn() {
        let gate = ChannelGate(limit: 2)
        var ran: [Int] = []
        for n in 1...4 { gate.enter { ran.append(n) } }
        XCTAssertEqual(ran, [1, 2], "two at once")
        XCTAssertEqual(gate.open, 2)
        XCTAssertEqual(gate.queued, 2)
        gate.leave()
        XCTAssertEqual(ran, [1, 2, 3], "the next in its place, in order")
        XCTAssertEqual(gate.open, 2)
        gate.leave()
        gate.leave()
        XCTAssertEqual(ran, [1, 2, 3, 4])
        XCTAssertEqual(gate.open, 1)
        gate.leave()
        gate.leave()
        XCTAssertEqual(gate.open, 0, "never below none")
    }

    func testTheStandardLimitIsUnderSSHDsOwn() {
        // sshd's MaxSessions is ten unless set; the app's HTTP session
        // opens up to sixteen connections to a tunnel's port.
        XCTAssertLessThan(ChannelGate.standardLimit, 10)
        XCTAssertEqual(ChannelGate().limit, ChannelGate.standardLimit)
    }
}

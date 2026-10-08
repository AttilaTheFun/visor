// What the connect form says a pasted code adds: the first path this
// device can take, over SSH only where it has SSH.

import VisorProtocol
@testable import VisorUI
import XCTest

final class ConnectFormTests: XCTestCase {
    private let sshFirst = ConnectionCode(name: "MacBook", host: "ssh://logan@100.73.57.115", password: "pw", id: "mb",
                                          paths: ["http://100.73.57.115:7433", "http://192.168.4.60:7433"])

    @MainActor
    func testTheSummaryNamesAPathTheDeviceCanTake() {
        XCTAssertEqual(ConnectForm.summary(of: sshFirst, canSSH: true), "MacBook over SSH, logan@100.73.57.115")
        XCTAssertEqual(ConnectForm.summary(of: sshFirst, canSSH: false), "MacBook at http://100.73.57.115:7433")
        let sshOnly = ConnectionCode(name: "MacBook", host: "ssh://logan@100.73.57.115", password: "pw")
        XCTAssertEqual(ConnectForm.summary(of: sshOnly, canSSH: false), "MacBook, over SSH only, which this app cannot use")
    }
}

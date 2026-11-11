// What the log calls a client: its name from its reports and the start of
// its id, so a client that drops can be told from the others.

import Foundation
import VisorProtocol
@testable import VisorServer
import VisorSystem
import XCTest

/// A connection that goes nowhere.
@MainActor
private final class SilentStream: ByteStream {
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {}
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { sent?() }
    func close() {}
}

@MainActor
final class ClientLogTests: ServerTestCase {
    private var server: VisorServer!

    override func setUp() async throws {
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-client-log-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: Self.freePort())
    }

    override func tearDown() async throws {
        server.stop()
    }

    func testAClientIsNamedByItsReports() {
        let client = ClientConnection(stream: SilentStream())
        XCTAssertEqual(server.describe(client), "a client that gave no id")
        client.clientID = "1a2b3c4d-5e6f-7a8b-9c0d-ef1234567890"
        XCTAssertEqual(server.describe(client), "client 1a2b3c4d")
        let report = DirectoryReport(client: "1a2b3c4d-5e6f-7a8b-9c0d-ef1234567890", clientName: "Logan’s MacBook Pro", servers: [])
        server.directory[report.client] = ClientDirectoryEntry(report: report, at: Date())
        XCTAssertEqual(server.describe(client), "Logan’s MacBook Pro (client 1a2b3c4d)")
    }
}

// What the log calls a client: its name from its reports and the start of
// its id, so a client that drops can be told from the others.

import Foundation
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

/// A connection that goes nowhere.
@MainActor
private final class SilentStream: ByteStream {
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {}
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { sent?() }
    func close() {}
}

extension ServerTests {
@Suite @MainActor final class ClientLogTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-client-log-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
    }

    isolated deinit {
        server.stop()
    }

    @Test func testAClientIsNamedByItsReports() {
        let client = ClientConnection(stream: SilentStream())
        #expect(server.describe(client) == "a client that gave no id")
        client.clientID = "1a2b3c4d-5e6f-7a8b-9c0d-ef1234567890"
        #expect(server.describe(client) == "client 1a2b3c4d")
        let report = DirectoryReport(client: "1a2b3c4d-5e6f-7a8b-9c0d-ef1234567890", clientName: "Logan’s MacBook Pro", servers: [])
        server.directory[report.client] = ClientDirectoryEntry(report: report, at: Date())
        #expect(server.describe(client) == "Logan’s MacBook Pro (client 1a2b3c4d)")
    }
}
}

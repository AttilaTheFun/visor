// The headless client's WebSockets: none. The fixture's computer is
// answered in the client (FixtureAgentServer) and opens no socket; a real
// computer added here fails to connect, as one out of reach does.

import VisorServices

@MainActor
final class OfflineSocketService: VisorSocketService {
    private var nextID: Int32 = 0

    func open(url: String) -> Int32 {
        nextID += 1
        return nextID
    }

    func send(id: Int32, text: String) {}

    func disconnect(id: Int32) {}

    /// Gone at once: the socket never opened.
    func next(id: Int32) async throws -> String { throw OfflineHTTPService.Offline() }

    func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}

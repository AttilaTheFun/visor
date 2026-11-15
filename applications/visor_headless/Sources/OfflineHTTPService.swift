// The headless client's HTTP: none, as its sockets (OfflineSocketService).

import VisorServices

struct OfflineHTTPService: VisorHTTPService {
    struct Offline: Error, CustomStringConvertible {
        var description: String { "the headless client has no network" }
    }

    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        throw Offline()
    }
}

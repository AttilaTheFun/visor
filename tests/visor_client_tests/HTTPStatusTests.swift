// The status behind a request's error, read from its words with the
// standard library alone (the client builds for the browser too).

import VisorServices
import XCTest

final class HTTPStatusTests: XCTestCase {
    private struct Service: VisorHTTPService {
        func request(method: String, url: String, body: String, authorization: String) async throws -> String { "" }
    }
    private struct Failure: Error, CustomStringConvertible { let description: String }

    func testStatusIsReadFromTheError() {
        let service = Service()
        XCTAssertEqual(service.status(of: Failure(description: "HTTP 401: Wrong password")), 401)
        XCTAssertEqual(service.status(of: Failure(description: "request failed: HTTP 503")), 503)
        XCTAssertNil(service.status(of: Failure(description: "The network connection was lost")))
        XCTAssertNil(service.status(of: Failure(description: "HTTP")))
        XCTAssertNil(service.status(of: Failure(description: "HTTP nope")))
    }
}

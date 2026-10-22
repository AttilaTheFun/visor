import Foundation
import OSSClient

/// oss's requests (OSSClient's) through the platform's own HTTP client, as
/// the server's other requests go: URLSession on Apple's systems,
/// FoundationNetworking on Linux and Windows, a fake in the tests.
struct PlatformOSSTransport: OSSTransport {
    func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        let outgoing = OutgoingRequest(url: request.url.absoluteString, method: request.method, headers: request.headers,
                                       body: request.body ?? Data(), timeout: request.timeout)
        do {
            let answer = try await ServerPlatform.current.fetching.fetch(outgoing)
            return OSSHTTPResponse(status: answer.status, headers: answer.headers, body: answer.body)
        } catch {
            throw OSSError(status: 0, message: "oss at \(request.url.host ?? request.url.absoluteString) can't be reached: \(error.localizedDescription)")
        }
    }
}

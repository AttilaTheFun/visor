import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stops every redirect: the response (with its Location) comes back as is.
/// It keeps nothing, so it is Sendable as it is.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    #if canImport(FoundationNetworking)
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
    #else
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
    #endif
}

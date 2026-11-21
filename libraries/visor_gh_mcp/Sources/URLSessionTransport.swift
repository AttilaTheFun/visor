import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub over URLSession: ephemeral (no cache, no cookies), redirects
/// stopped so a token never follows one off api.github.com. Its sessions
/// are its only state, kept for its life.
public final class URLSessionTransport: GitHubTransport, Sendable {
    private let api: URLSession
    private let plain: URLSession
    private let base = "https://api.github.com"

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        api = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        let downloads = URLSessionConfiguration.ephemeral
        downloads.timeoutIntervalForRequest = 120
        downloads.timeoutIntervalForResource = 1800
        downloads.urlCache = nil
        plain = URLSession(configuration: downloads)
    }

    public func send(_ request: GitHubRequest, token: String) async throws -> GitHubResponse {
        var text = request.path.hasPrefix("https://") ? request.path : base + request.path
        if !request.query.isEmpty {
            text += (text.contains("?") ? "&" : "?")
                + request.query.sorted(by: { $0.key < $1.key }).map { "\(encodeSegment($0.key))=\(encodeSegment($0.value))" }.joined(separator: "&")
        }
        guard let url = URL(string: text), url.host == "api.github.com" else {
            throw ToolError.failed("Not a GitHub API URL: \(Redact.line(text))")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        urlRequest.setValue("gh_mcp/\(serverVersion)", forHTTPHeaderField: "User-Agent")
        if let body = request.body {
            urlRequest.httpBody = body.data()
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(urlRequest, on: api)
    }

    public func fetch(_ url: String) async throws -> GitHubResponse {
        guard let target = URL(string: url), target.scheme == "https" else { throw ToolError.failed("Not an https URL") }
        var request = URLRequest(url: target)
        request.setValue("gh_mcp/\(serverVersion)", forHTTPHeaderField: "User-Agent")
        return try await perform(request, on: plain)
    }

    public func download(_ url: String, to file: String) async throws {
        guard let target = URL(string: url), target.scheme == "https" else { throw ToolError.failed("Not an https URL") }
        var request = URLRequest(url: target)
        request.setValue("gh_mcp/\(serverVersion)", forHTTPHeaderField: "User-Agent")
        let session = plain
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.downloadTask(with: request) { location, response, error in
                if let error {
                    continuation.resume(throwing: ToolError.failed("The download failed: \(error.localizedDescription)"))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status), let location else {
                    continuation.resume(throwing: ToolError.failed("The download's storage answered \(status)"))
                    return
                }
                do {
                    try? FileManager.default.removeItem(atPath: file)
                    try FileManager.default.moveItem(atPath: location.path, toPath: file)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: ToolError.failed("The download could not be kept: \(error.localizedDescription)"))
                }
            }.resume()
        }
    }

    private func perform(_ request: URLRequest, on session: URLSession) async throws -> GitHubResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: ToolError.failed("GitHub could not be reached: \(error.localizedDescription)"))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: ToolError.failed("GitHub's answer was not HTTP"))
                    return
                }
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
                }
                continuation.resume(returning: GitHubResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }.resume()
        }
    }
}
